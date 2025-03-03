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

# Function to verify TPU access using test_tpu_access.py
verify_tpu_access() {
  log "Starting TPU hardware verification..."
  
  # Path to the verification script
  VERIFY_SCRIPT="test_tpu_access.py"
  
  # Ensure the verification script is mounted
  log "Checking for verification script..."
  if ! ensure_file_mounted "$VERIFY_SCRIPT"; then
    log_error "Cannot run verification - test_tpu_access.py not found and couldn't be mounted."
    return 1
  fi
  
  # Get the file path on TPU VM
  tpu_file_path=$(check_file_exists_on_tpu "$VERIFY_SCRIPT")
  
  if [ -z "$tpu_file_path" ]; then
    log_error "Could not determine path for verification script on TPU VM"
    return 1
  fi
  
  log_success "Found verification script at $tpu_file_path"
  
  # Get the Docker container path for the script
  docker_file_path=$(echo "$tpu_file_path" | sed "s|${TPU_HOST_PATH}|${DOCKER_CONTAINER_PATH}|g")
  
  # Prepare Docker command with TPU library mount
  log "Running TPU verification test..."
  DOCKER_CMD="docker run --rm --privileged \
    --device=/dev/accel0 \
    -e PJRT_DEVICE=TPU \
    -e XLA_USE_BF16=1 \
    -e PYTHONUNBUFFERED=1 \
    -e TPU_NAME=local \
    -e TPU_LOAD_LIBRARY=0 \
    -e TF_PLUGGABLE_DEVICE_LIBRARY_PATH=$TF_PLUGGABLE_DEVICE_LIBRARY_PATH \
    -e NEXT_PLUGGABLE_DEVICE_USE_C_API=true \
    -v ${TPU_HOST_PATH}:${DOCKER_CONTAINER_PATH} \
    -v ${TPU_HOST_PATH}/utils:${DOCKER_CONTAINER_PATH}/utils \
    -v $TF_PLUGGABLE_DEVICE_LIBRARY_PATH:$TF_PLUGGABLE_DEVICE_LIBRARY_PATH \
    -w /app \
    gcr.io/$PROJECT_ID/tpu-hello-world:v1 \
    python $docker_file_path"
  
  # Try running with regular docker
  log "Running TPU verification test..."
  ssh_with_timeout "$DOCKER_CMD" 300
  
  run_status=$?
  if [ $run_status -eq 0 ]; then
    log_success "TPU verification test passed successfully!"
    return 0
  else
    log_warning "TPU verification test failed with status code $run_status"
    
    # Try with sudo if regular docker failed
    log "Retrying with sudo..."
    ssh_with_timeout "sudo $DOCKER_CMD" 300
    
    retry_status=$?
    if [ $retry_status -eq 0 ]; then
      log_success "TPU verification test passed successfully with sudo!"
      return 0
    else
      log_error "TPU verification test still failed with sudo (status code $retry_status)"
      log_error "Your TPU hardware may not be properly configured."
      return 1
    fi
  fi
}

show_usage() {
  echo "Usage: $0 [--verify] [file1.py|file1.sh] [file2.py|file2.sh ...] [script_args...]"
  echo ""
  echo "Run Python or shell files on the TPU VM that have already been mounted."
  echo ""
  echo "Options:"
  echo "  --verify              Run TPU hardware verification test only"
  echo ""
  echo "Arguments:"
  echo "  file1.py, file2.sh     Files to execute (Python or shell scripts, must be mounted already)"
  echo "  script_args            Optional: Arguments to pass to the last file"
  echo ""
  echo "Examples:"
  echo "  $0 --verify               # Verify TPU hardware setup"
  echo "  $0 example.py             # Run a Python file"
  echo "  $0 run_example.sh         # Run a shell script"
  echo "  $0 example.py train.py    # Run multiple files sequentially" 
  echo "  $0 train.py --epochs 10   # Run with arguments"
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

# Check for TPU library path (added for TPU hardware access)
if [[ -z "$TF_PLUGGABLE_DEVICE_LIBRARY_PATH" ]]; then
  log_warning "TF_PLUGGABLE_DEVICE_LIBRARY_PATH not set. Using default '/lib/libtpu.so'"
  TF_PLUGGABLE_DEVICE_LIBRARY_PATH="/lib/libtpu.so"
else
  log "Using TPU library at: $TF_PLUGGABLE_DEVICE_LIBRARY_PATH"
fi

# Check if we should run in verification mode only
if [[ "$1" == "--verify" ]]; then
  # Run only verification and exit
  verify_tpu_access
  exit $?
fi

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

# Check if the TPU library exists on the TPU VM
log "Checking TPU library access..."
tpu_lib_exists=$(ssh_with_timeout "test -f $TF_PLUGGABLE_DEVICE_LIBRARY_PATH && echo 'exists'" | grep -q "exists"; echo $?)
if [[ $tpu_lib_exists -ne 0 ]]; then
  log_warning "TPU library not found at $TF_PLUGGABLE_DEVICE_LIBRARY_PATH"
  log "Searching for TPU library..."
  TPU_LIB_PATH=$(ssh_with_timeout "find / -name 'libtpu.so' 2>/dev/null | head -n 1" | tr -d '\r')
  
  if [[ -n "$TPU_LIB_PATH" ]]; then
    log_success "Found TPU library at: $TPU_LIB_PATH"
    TF_PLUGGABLE_DEVICE_LIBRARY_PATH="$TPU_LIB_PATH"
    
    # Also update the .env file with the discovered path if needed
    if [[ -f "$PROJECT_DIR/source/.env" && -w "$PROJECT_DIR/source/.env" ]]; then
      log "Updating TPU library path in .env file"
      # Different sed syntax for macOS vs Linux/Windows
      if [[ "$(uname)" == "Darwin" ]]; then
        # macOS requires an empty string for -i
        sed -i '' "s|^TF_PLUGGABLE_DEVICE_LIBRARY_PATH=.*$|TF_PLUGGABLE_DEVICE_LIBRARY_PATH=$TPU_LIB_PATH|" "$PROJECT_DIR/source/.env"
      else
        # Linux/Windows doesn't need an empty string
        sed -i "s|^TF_PLUGGABLE_DEVICE_LIBRARY_PATH=.*$|TF_PLUGGABLE_DEVICE_LIBRARY_PATH=$TPU_LIB_PATH|" "$PROJECT_DIR/source/.env"
      fi
    else
      log_warning "Cannot update .env file - not writable or does not exist"
    fi
  else
    log_warning "Could not find TPU library on TPU VM. TPU access may not work properly."
  fi
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
  
  # Prepare Docker command with TPU library mount
  DOCKER_CMD="docker run --rm --privileged \
    --device=/dev/accel0 \
    -e PJRT_DEVICE=TPU \
    -e XLA_USE_BF16=1 \
    -e PYTHONUNBUFFERED=1 \
    -e TPU_NAME=local \
    -e TPU_LOAD_LIBRARY=0 \
    -e TF_PLUGGABLE_DEVICE_LIBRARY_PATH=$TF_PLUGGABLE_DEVICE_LIBRARY_PATH \
    -e NEXT_PLUGGABLE_DEVICE_USE_C_API=true \
    -v ${TPU_HOST_PATH}:${DOCKER_CONTAINER_PATH} \
    -v ${TPU_HOST_PATH}/utils:${DOCKER_CONTAINER_PATH}/utils \
    -v $TF_PLUGGABLE_DEVICE_LIBRARY_PATH:$TF_PLUGGABLE_DEVICE_LIBRARY_PATH \
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