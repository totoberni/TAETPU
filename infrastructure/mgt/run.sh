#!/bin/bash

# --- Basic setup ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/infrastructure/utils/common.sh"

# --- Parse command-line arguments ---
PYTHON_FILE=""
FILE_ARGS=""

# Display help if no arguments or help flag
if [ $# -eq 0 ] || [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
  echo "Usage: $0 path/to/file.py [args...]"
  echo "Execute Python code inside the Docker container using mounted files."
  echo ""
  echo "Arguments:"
  echo "  path/to/file.py     Path to Python file relative to src directory"
  echo "  [args...]           Arguments to pass to the Python script"
  exit 0
fi

# First argument is the file
PYTHON_FILE="$1"
shift

# Any remaining arguments are passed to the file
FILE_ARGS="$@"

# --- Load environment variables ---
source "$PROJECT_DIR/config/.env"
check_env_vars "PROJECT_ID" || exit 1

# --- Check if file exists locally ---
if [ ! -f "$PROJECT_DIR/src/$PYTHON_FILE" ]; then
  log_error "File $PYTHON_FILE not found in src directory."
  exit 1
fi

# --- Check TPU VM connectivity ---
log_section "Checking TPU VM Connectivity"
if ! gcloud compute tpus tpu-vm describe "$TPU_NAME" \
     --zone="$TPU_ZONE" \
     --project="$PROJECT_ID" &>/dev/null; then
  log_error "Cannot connect to TPU VM $TPU_NAME. Please ensure it is running."
  exit 1
fi
log_success "TPU VM $TPU_NAME is accessible."

# --- Check if Docker container is running ---
log_section "Docker Container Status"
CONTAINER_NAME="tae-tpu-container"

log "Checking if Docker container is running..."
CONTAINER_ID=$(docker ps -q -f name=$CONTAINER_NAME)

if [ -z "$CONTAINER_ID" ]; then
  log_warning "Container $CONTAINER_NAME is not running"
  
  # Check if container exists but is stopped
  STOPPED_ID=$(docker ps -aq -f name=$CONTAINER_NAME)
  if [ -n "$STOPPED_ID" ]; then
    log "Container exists but is stopped. Starting container..."
    docker start $CONTAINER_NAME
  else
    log_error "Container does not exist. Please run mount.sh first to create and setup the container."
    exit 1
  fi
  
  # Check again to confirm container is running
  CONTAINER_ID=$(docker ps -q -f name=$CONTAINER_NAME)
  if [ -z "$CONTAINER_ID" ]; then
    log_error "Failed to start Docker container"
    exit 1
  fi
fi

log_success "Container $CONTAINER_NAME is running with ID: $CONTAINER_ID"

# --- Search for file in container ---
log "Searching for file in container..."
FILE_PATH=$(docker exec $CONTAINER_NAME find /app/mount -name $(basename $PYTHON_FILE) -type f 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  log_warning "File $PYTHON_FILE not found in container."
  log "Mounting file to container using mount.sh..."
  
  # Run the mount.sh script to mount the specific file
  "$SCRIPT_DIR/mount.sh" "$PYTHON_FILE"
  
  # Search for the file again
  FILE_PATH=$(docker exec $CONTAINER_NAME find /app/mount -name $(basename $PYTHON_FILE) -type f 2>/dev/null)
  
  if [ -z "$FILE_PATH" ]; then
    log_error "Failed to mount and find file $PYTHON_FILE in container"
    exit 1
  fi
  log_success "File mounted successfully"
fi

log_success "Found file at $FILE_PATH"

# --- Run the Python file in the container ---
log_section "Executing Python File in Container"
log "Running: python $FILE_PATH $FILE_ARGS"

# Execute the Python file with arguments
docker exec -it $CONTAINER_NAME python $FILE_PATH $FILE_ARGS
EXIT_CODE=$?

# Check execution status
if [ $EXIT_CODE -eq 0 ]; then
  log_success "Execution completed successfully"
else
  log_error "Execution failed with exit code $EXIT_CODE"
fi

exit $EXIT_CODE