#!/bin/bash

# --- DETERMINE SCRIPT AND PROJECT DIRECTORIES ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- DEFINE PATH CONSTANTS - Use these consistently across all scripts ---
TPU_HOST_PATH="/tmp/dev/src"
DOCKER_CONTAINER_PATH="/app/dev/src"

# --- IMPORT COMMON FUNCTIONS ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

# --- HELPER FUNCTIONS ---
# Function to check if a file exists on the TPU VM
check_file_exists_on_tpu() {
  local file=$1
  local timeout=${2:-10}
  
  # Check in main directory
  if ssh_with_timeout "test -f ${TPU_HOST_PATH}/${file} && echo 'exists'" $timeout | grep -q "exists"; then
    echo "${TPU_HOST_PATH}/${file}"
    return 0
  # Check in utils directory
  elif ssh_with_timeout "test -f ${TPU_HOST_PATH}/utils/${file} && echo 'exists'" $timeout | grep -q "exists"; then
    echo "${TPU_HOST_PATH}/utils/${file}"
    return 0
  else
    return 1
  fi
}

# Function to mount a file if it's not already on the TPU VM
ensure_file_mounted() {
  local file=$1
  
  # Check if file exists on TPU VM
  if check_file_exists_on_tpu "$file" > /dev/null; then
    log_success "File $file is already mounted on TPU VM"
    return 0
  fi
  
  # File not found, try to mount it
  log_warning "File $file not found on TPU VM. Attempting to mount it..."
  
  if [[ -f "$PROJECT_DIR/dev/mgt/mount.sh" ]]; then
    "$PROJECT_DIR/dev/mgt/mount.sh" "$file"
    if [ $? -eq 0 ]; then
      log_success "Successfully mounted $file"
      return 0
    else
      log_error "Failed to mount $file"
      return 1
    fi
  else
    log_error "mount.sh not found. Cannot mount file automatically."
    return 1
  fi
}

show_usage() {
  echo "Usage: $0 [file1.py|file1.sh] [file2.py|file2.sh ...] [script_args...]"
  echo ""
  echo "Run Python or shell files on the TPU VM that have already been mounted."
  echo ""
  echo "Arguments:"
  echo "  file1.py, file2.sh     Files to execute (Python or shell scripts, must be mounted already)"
  echo "  script_args            Optional: Arguments to pass to the last file"
  echo ""
  echo "Examples:"
  echo "  $0 example.py               # Run a Python file"
  echo "  $0 run_example.sh           # Run a shell script"
  echo "  $0 example.py train.py      # Run multiple files sequentially" 
  echo "  $0 train.py --epochs 10     # Run with arguments"
  exit 1
}

# --- MAIN SCRIPT ---
if [ $# -eq 0 ]; then
  show_usage
fi

log 'Loading environment variables...'
source "$PROJECT_DIR/source/.env"
log 'Environment variables loaded successfully'

# Validate required environment variables
check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_NAME"

# Parse arguments
FILES_TO_RUN=()
SCRIPT_ARGS=()
COLLECTING_FILES=true

for arg in "$@"; do
  if [[ "$COLLECTING_FILES" == "true" && ("$arg" == *.py || "$arg" == *.sh) ]]; then
    FILES_TO_RUN+=("$arg")
  else
    COLLECTING_FILES=false
    SCRIPT_ARGS+=("$arg")
  fi
done

# Check if utils directory is mounted, mount it if not present
log "Checking utils directory..."
if ! ssh_with_timeout "test -d ${TPU_HOST_PATH}/utils && echo 'exists'" | grep -q "exists"; then
  log_warning "Utils directory not found on TPU VM. Mounting it now..."
  
  if [[ -f "$PROJECT_DIR/dev/mgt/mount.sh" ]]; then
    "$PROJECT_DIR/dev/mgt/mount.sh" --utils
    if [ $? -eq 0 ]; then
      log_success "Successfully mounted utils directory"
    else
      log_error "Failed to mount utils directory. Scripts may fail if they need common logging functions."
    fi
  else
    log_error "mount.sh not found. Cannot mount utils directory automatically."
  fi
else
  log_success "Utils directory found on TPU VM"
fi

# Validate that files exist on TPU VM or attempt to mount them
log "Checking files on TPU VM..."
VALID_FILES=()

for file in "${FILES_TO_RUN[@]}"; do
  # Try to ensure file is mounted
  if ensure_file_mounted "$file"; then
    # Get the full path to the file on TPU VM
    tpu_file_path=$(check_file_exists_on_tpu "$file")
    if [ -n "$tpu_file_path" ]; then
      VALID_FILES+=("$tpu_file_path")
      log_success "Verified file exists: $file at $tpu_file_path"
    else
      log_warning "Could not determine path for $file on TPU VM"
    fi
  else
    log_warning "Could not mount or find $file on TPU VM - skipping"
  fi
done

if [ ${#VALID_FILES[@]} -eq 0 ]; then
  log_error "No valid files found on TPU VM. Please mount files first using mount.sh."
  exit 1
fi

# Run each file
log "Running ${#VALID_FILES[@]} file(s) on TPU VM..."
for (( i=0; i<${#VALID_FILES[@]}; i++ )); do
  file="${VALID_FILES[$i]}"
  log "Executing: $file"
  
  # Get the relative path to use inside Docker container
  docker_file_path=$(echo "$file" | sed "s|${TPU_HOST_PATH}|${DOCKER_CONTAINER_PATH}|g")
  
  # Determine if this is a Python file or shell script
  if [[ "$file" == *.py ]]; then
    RUN_CMD="python"
  elif [[ "$file" == *.sh ]]; then
    RUN_CMD="bash"
    
    # Ensure shell scripts are executable
    log "Ensuring script is executable..."
    ssh_with_timeout "chmod +x ${file}" 10
  else
    log_warning "Unsupported file type for $file. Only .py and .sh files are supported."
    continue
  fi
  
  # Prepare Docker command
  DOCKER_CMD="docker run --rm --privileged \
    --device=/dev/accel0 \
    -e PJRT_DEVICE=TPU \
    -e XLA_USE_BF16=1 \
    -e PYTHONUNBUFFERED=1 \
    -v ${TPU_HOST_PATH}:${DOCKER_CONTAINER_PATH} \
    -v ${TPU_HOST_PATH}/utils:${DOCKER_CONTAINER_PATH}/utils \
    -w /app \
    gcr.io/$PROJECT_ID/tpu-hello-world:v1 \
    $RUN_CMD $docker_file_path"
  
  # Add arguments if this is the last file and there are arguments
  if [[ $i -eq $(( ${#VALID_FILES[@]} - 1 )) && ${#SCRIPT_ARGS[@]} -gt 0 ]]; then
    DOCKER_CMD="$DOCKER_CMD ${SCRIPT_ARGS[*]}"
    log "With arguments: ${SCRIPT_ARGS[*]}"
  fi
  
  # Try running with regular docker
  log "Running docker command..."
  ssh_with_timeout "$DOCKER_CMD" 300
  
  run_status=$?
  if [ $run_status -eq 0 ]; then
    log_success "File executed successfully: $file"
  else
    log_warning "Execution failed for $file with status code $run_status"
    
    # Try with sudo if regular docker failed
    log "Retrying with sudo..."
    ssh_with_timeout "sudo $DOCKER_CMD" 300
    
    retry_status=$?
    if [ $retry_status -eq 0 ]; then
      log_success "File executed successfully with sudo: $file"
    else
      log_warning "Execution still failed with sudo for $file with status code $retry_status"
    fi
  fi
done

log_success "Execution complete for all files"
exit 0 