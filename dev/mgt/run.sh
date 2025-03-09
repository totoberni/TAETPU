#!/bin/bash

# --- DETERMINE SCRIPT AND PROJECT DIRECTORIES ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- IMPORT COMMON FUNCTIONS ---
source "$PROJECT_DIR/src/utils/common.sh"

show_usage() {
  echo "Usage: $0 [filename1.py filename2.py ...] [script_args...]"
  echo ""
  echo "Run Python file(s) on the TPU VM that have been mounted."
  echo ""
  echo "Arguments:"
  echo "  filename1.py filename2.py   Python files to execute (must be in /app/mount)"
  echo "  script_args                 Optional: Arguments to pass to the last Python script"
  echo ""
  echo "Examples:"
  echo "  $0 example.py               # Run a single file"
  echo "  $0 train.py --epochs 10     # Run with arguments"
  exit 1
}

# Exit if no arguments
[ $# -eq 0 ] && show_usage

# Load environment variables
source "$PROJECT_DIR/source/.env"

# Check for required environment variables
check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_NAME" || exit 1

# Configure Docker authentication on TPU VM
log "Configuring Docker authentication on TPU VM..."
vmssh "gcloud auth configure-docker gcr.io --quiet"

# Parse arguments - collect Python files and script arguments
FILES_TO_RUN=()
SCRIPT_ARGS=()
COLLECTING_FILES=true

for arg in "$@"; do
  if [[ "$COLLECTING_FILES" == "true" && "$arg" == *.py ]]; then
    # Clean up any path separators and get just the filename
    clean_file=$(basename "$arg")
    FILES_TO_RUN+=("$clean_file")
  else
    COLLECTING_FILES=false
    SCRIPT_ARGS+=("$arg")
  fi
done

# Define Docker image path
DOCKER_IMAGE="gcr.io/${PROJECT_ID}/tae-tpu:v1"

# Mount path on TPU VM
MOUNT_PATH="/tmp/app/mount"
CONTAINER_MOUNT_PATH="/app/mount"

# Pull Docker image if needed
log "Ensuring Docker image is available..."
vmssh "docker pull $DOCKER_IMAGE || echo 'Using cached image'"

# Run each file
for (( i=0; i<${#FILES_TO_RUN[@]}; i++ )); do
  file="${FILES_TO_RUN[$i]}"
  log "Running: $file"
  
  # Verify file exists on TPU VM
  if ! vmssh "test -f $MOUNT_PATH/$file && echo 'File exists'" | grep -q "File exists"; then
    log_error "File $file not found in $MOUNT_PATH. Please run mount.sh first."
    continue
  fi
  
  # Container file path
  container_file="$CONTAINER_MOUNT_PATH/$file"
  
  # Prepare Docker run command
  docker_cmd="docker run --rm --privileged"
  
  # Add device
  docker_cmd+=" --device=/dev/accel0"
  
  # Add environment variables
  docker_cmd+=" -e PJRT_DEVICE=TPU"
  docker_cmd+=" -e XLA_USE_BF16=1"
  docker_cmd+=" -e PYTHONUNBUFFERED=1"
  docker_cmd+=" -e TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so"
  docker_cmd+=" -e NEXT_PLUGGABLE_DEVICE_USE_C_API=true"
  
  # Add volume mount
  docker_cmd+=" -v $MOUNT_PATH:$CONTAINER_MOUNT_PATH"
  docker_cmd+=" -v /lib/libtpu.so:/lib/libtpu.so"
  
  # Set working directory
  docker_cmd+=" -w /app"
  
  # Add image
  docker_cmd+=" $DOCKER_IMAGE"
  
  # Add command and file to run
  docker_cmd+=" python $container_file"
  
  # Add script args (only for the last file)
  if [[ $i -eq $(( ${#FILES_TO_RUN[@]} - 1 )) && ${#SCRIPT_ARGS[@]} -gt 0 ]]; then
    docker_cmd+=" ${SCRIPT_ARGS[*]}"
  fi
  
  # Execute Docker run command on TPU VM
  log "Executing Docker command..."
  if ! vmssh "$docker_cmd"; then
    log_warning "Command failed, trying with sudo..."
    if ! vmssh "sudo $docker_cmd"; then
      log_error "Execution failed even with sudo for $file"
    else
      log_success "Successfully executed $file with sudo"
    fi
  else
    log_success "Successfully executed $file"
  fi
done

log_success "All executions completed"
exit 0 