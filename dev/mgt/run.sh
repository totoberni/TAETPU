#!/bin/bash

# --- DETERMINE SCRIPT AND PROJECT DIRECTORIES ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- IMPORT COMMON FUNCTIONS ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

show_usage() {
  echo "Usage: $0 [filename1.py filename2.py ...] [script_args...]"
  echo ""
  echo "Run Python file(s) on the TPU VM that have already been mounted."
  echo ""
  echo "Arguments:"
  echo "  filename1.py filename2.py   Python files to execute (must be mounted already)"
  echo "  script_args                 Optional: Arguments to pass to the last Python script"
  echo ""
  echo "Examples:"
  echo "  $0 example.py               # Run a single file"
  echo "  $0 example.py train.py      # Run multiple files sequentially" 
  echo "  $0 train.py --epochs 10     # Run with arguments"
  exit 1
}

# Main script starts here
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
  if [[ "$COLLECTING_FILES" == "true" && "$arg" == *.py ]]; then
    FILES_TO_RUN+=("$arg")
  else
    COLLECTING_FILES=false
    SCRIPT_ARGS+=("$arg")
  fi
done

# Target directory on TPU VM - Let's check multiple possible paths
POSSIBLE_DIRS=("/tmp/dev/src" "/tmp/src" "/home/$(ssh_with_timeout "whoami")/dev/src")

# Validate that files exist on TPU VM with better debugging
log "Checking for files on TPU VM..."

# First, list directories to help debug
for dir in "${POSSIBLE_DIRS[@]}"; do
  log "Checking directory: $dir"
  ssh_with_timeout "if [ -d $dir ]; then echo 'Directory exists:'; ls -la $dir; else echo 'Directory does not exist'; fi" 30
done

VALID_FILES=()
for file in "${FILES_TO_RUN[@]}"; do
  file_found=false
  
  # Try all possible directories
  for dir in "${POSSIBLE_DIRS[@]}"; do
    if ssh_with_timeout "test -f ${dir}/${file} && echo 'exists'" | grep -q "exists"; then
      log_success "Found ${file} in ${dir}"
      VALID_FILES+=("${dir}/${file}")
      file_found=true
      break
    elif ssh_with_timeout "test -f ${dir}/utils/${file} && echo 'exists'" | grep -q "exists"; then
      log_success "Found ${file} in ${dir}/utils"
      VALID_FILES+=("${dir}/utils/${file}")
      file_found=true
      break
    fi
  done
  
  if [ "$file_found" = false ]; then
    log_warning "${file} not found on TPU VM. Make sure to mount it first using mount.sh"
  fi
done

if [ ${#VALID_FILES[@]} -eq 0 ]; then
  log_error "No valid Python files found on TPU VM. Please mount files first using mount.sh."
  exit 1
fi

# Run each file
log "Running ${#VALID_FILES[@]} file(s) on TPU VM..."
for (( i=0; i<${#VALID_FILES[@]}; i++ )); do
  file="${VALID_FILES[$i]}"
  log "Executing: $file"
  
  # Get the mount point for Docker mapping based on the actual file path
  for dir in "${POSSIBLE_DIRS[@]}"; do
    if [[ "$file" == "$dir"* ]]; then
      # Convert the host path to container path
      docker_file_path=$(echo "$file" | sed "s|$dir|/app/dev/src|g")
      break
    fi
  done
  
  # Apply script args only to the last file
  if [[ $i -eq $(( ${#VALID_FILES[@]} - 1 )) && ${#SCRIPT_ARGS[@]} -gt 0 ]]; then
    log "With arguments: ${SCRIPT_ARGS[*]}"
    ssh_with_timeout "docker run --rm --privileged \
      --device=/dev/accel0 \
      -e PJRT_DEVICE=TPU \
      -e XLA_USE_BF16=1 \
      -e PYTHONUNBUFFERED=1 \
      -v /tmp/dev/src:/app/dev/src \
      -v /tmp/src:/app/dev/src \
      -v /home/\$(whoami)/dev/src:/app/dev/src \
      -w /app \
      gcr.io/$PROJECT_ID/tpu-hello-world:v1 \
      python $docker_file_path ${SCRIPT_ARGS[*]}" 300
  else
    ssh_with_timeout "docker run --rm --privileged \
      --device=/dev/accel0 \
      -e PJRT_DEVICE=TPU \
      -e XLA_USE_BF16=1 \
      -e PYTHONUNBUFFERED=1 \
      -v /tmp/dev/src:/app/dev/src \
      -v /tmp/src:/app/dev/src \
      -v /home/\$(whoami)/dev/src:/app/dev/src \
      -w /app \
      gcr.io/$PROJECT_ID/tpu-hello-world:v1 \
      python $docker_file_path" 300
  fi
  
  run_status=$?
  if [ $run_status -eq 0 ]; then
    log_success "File executed successfully: $file"
  else
    log_warning "Execution failed for $file with status code $run_status"
    
    # Try with sudo if regular docker failed
    log "Retrying with sudo..."
    if [[ $i -eq $(( ${#VALID_FILES[@]} - 1 )) && ${#SCRIPT_ARGS[@]} -gt 0 ]]; then
      ssh_with_timeout "sudo docker run --rm --privileged \
        --device=/dev/accel0 \
        -e PJRT_DEVICE=TPU \
        -e XLA_USE_BF16=1 \
        -e PYTHONUNBUFFERED=1 \
        -v /tmp/dev/src:/app/dev/src \
        -v /tmp/src:/app/dev/src \
        -v /home/\$(whoami)/dev/src:/app/dev/src \
        -w /app \
        gcr.io/$PROJECT_ID/tpu-hello-world:v1 \
        python $docker_file_path ${SCRIPT_ARGS[*]}" 300
    else
      ssh_with_timeout "sudo docker run --rm --privileged \
        --device=/dev/accel0 \
        -e PJRT_DEVICE=TPU \
        -e XLA_USE_BF16=1 \
        -e PYTHONUNBUFFERED=1 \
        -v /tmp/dev/src:/app/dev/src \
        -v /tmp/src:/app/dev/src \
        -v /home/\$(whoami)/dev/src:/app/dev/src \
        -w /app \
        gcr.io/$PROJECT_ID/tpu-hello-world:v1 \
        python $docker_file_path" 300
    fi
    
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