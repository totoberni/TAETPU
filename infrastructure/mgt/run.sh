#!/bin/bash

# --- Basic setup ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/infrastructure/utils/common.sh"

# Initialize script
init_script "Run Script in Docker Container"

# --- Parse command-line arguments ---
PYTHON_FILE=""
FILE_ARGS=""
FILE_TYPE="src" # Default to src files
USE_NAMED_VOLUMES=false

# Display help if no arguments or help flag
if [ $# -eq 0 ] || [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
  echo "Usage: $0 [--type file_type] [--named-volumes] path/to/file.py [args...]"
  echo "Execute Python code inside the Docker container using mounted files."
  echo ""
  echo "Options:"
  echo "  --type file_type     Type of file to run (src|datasets|models|checkpoints|logs|results)"
  echo "                       Default is 'src'"
  echo "  --named-volumes      Use Docker named volumes instead of host directories"
  echo "  path/to/file.py      Path to Python file relative to specified type directory"
  echo "  [args...]            Arguments to pass to the Python script"
  exit 0
fi

# Parse options
while [[ $# -gt 0 ]]; do
  case $1 in
    --type)
      if [ $# -lt 2 ]; then
        log_error "Missing file type after --type option"
        exit 1
      fi
      FILE_TYPE="$2"
      shift 2
      ;;
    --named-volumes)
      USE_NAMED_VOLUMES=true
      shift
      ;;
    -*)
      log_error "Unknown option: $1"
      exit 1
      ;;
    *)
      # First non-option argument is the file
      PYTHON_FILE="$1"
      shift
      # Any remaining arguments are passed to the file
      FILE_ARGS="$@"
      break
      ;;
  esac
done

if [ -z "$PYTHON_FILE" ]; then
  log_error "No Python file specified"
  exit 1
fi

# --- Load environment variables ---
source "$PROJECT_DIR/config/.env"
check_env_vars "PROJECT_ID" || exit 1

# Use environment variable if set, otherwise use command line flag
[ "${USE_NAMED_VOLUMES:-false}" = "true" ] && USE_NAMED_VOLUMES=true

# Use CONTAINER_NAME from .env if defined, otherwise use the default
CONTAINER_NAME="${CONTAINER_NAME:-tae-tpu-container}"
CONTAINER_TAG="${CONTAINER_TAG:-latest}"
IMAGE_NAME="${IMAGE_NAME:-eu.gcr.io/${PROJECT_ID}/tae-tpu:v1}"
VOLUME_PREFIX="${VOLUME_PREFIX:-tae}"

# --- Configure paths based on file type ---
case $FILE_TYPE in
  src)
    SOURCE_DIR="$PROJECT_DIR/src"
    CONTAINER_DIR="/app/mount"
    VOLUME_NAME="$VOLUME_PREFIX-src"
    ;;
  datasets)
    SOURCE_DIR="$PROJECT_DIR/datasets"
    CONTAINER_DIR="/app/datasets"
    VOLUME_NAME="$VOLUME_PREFIX-datasets"
    ;;
  models)
    SOURCE_DIR="$PROJECT_DIR/models"
    CONTAINER_DIR="/app/models"
    VOLUME_NAME="$VOLUME_PREFIX-models"
    ;;
  checkpoints)
    SOURCE_DIR="$PROJECT_DIR/checkpoints"
    CONTAINER_DIR="/app/checkpoints"
    VOLUME_NAME="$VOLUME_PREFIX-checkpoints"
    ;;
  logs)
    SOURCE_DIR="$PROJECT_DIR/logs"
    CONTAINER_DIR="/app/logs"
    VOLUME_NAME="$VOLUME_PREFIX-logs"
    ;;
  results)
    SOURCE_DIR="$PROJECT_DIR/results"
    CONTAINER_DIR="/app/results"
    VOLUME_NAME="$VOLUME_PREFIX-results"
    ;;
  *)
    log_error "Invalid file type: $FILE_TYPE"
    echo "Valid types are: src, datasets, models, checkpoints, logs, results"
    exit 1
    ;;
esac

# --- Check if file exists locally ---
if [ ! -f "$SOURCE_DIR/$PYTHON_FILE" ]; then
  log_warning "File $PYTHON_FILE not found in $FILE_TYPE directory."
  
  # If the file doesn't exist but the directory does, create an empty file with basic content
  DIR_PATH=$(dirname "$SOURCE_DIR/$PYTHON_FILE")
  if [ -d "$DIR_PATH" ]; then
    log "Creating empty Python file: $PYTHON_FILE"
    mkdir -p "$DIR_PATH"
    cat > "$SOURCE_DIR/$PYTHON_FILE" << EOF
#!/usr/bin/env python
"""
$PYTHON_FILE - Automatically generated file
"""

def main():
    print("Hello from $PYTHON_FILE!")
    
if __name__ == "__main__":
    main()
EOF
    log_success "Created new Python file: $PYTHON_FILE"
  else
    log_error "Directory for $PYTHON_FILE does not exist. Please create it first."
    exit 1
  fi
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

log "Checking if Docker container is running..."
CONTAINER_ID=$(docker ps -q -f name=$CONTAINER_NAME)

if [ -z "$CONTAINER_ID" ]; then
  log_warning "Container $CONTAINER_NAME is not running"
  
  # Check for container name mismatch
  if ! check_container_name_mismatch; then
    log_warning "Container name mismatch detected. Attempting to fix..."
    
    # Try to tag the image with the expected name
    for image in $(docker images --format "{{.Repository}}:{{.Tag}}"); do
      if [[ "$image" == *"tpu"* || "$image" == *"transformer"* || "$image" == *"gcr"* ]]; then
        log "Creating an alias for image name mismatch..."
        docker tag "$image" "${CONTAINER_NAME}:${CONTAINER_TAG}"
        log_success "Created image alias: $image -> ${CONTAINER_NAME}:${CONTAINER_TAG}"
        break
      fi
    done
  fi
  
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
FILE_PATH=$(docker exec $CONTAINER_NAME find $CONTAINER_DIR -name $(basename $PYTHON_FILE) -type f 2>/dev/null)

if [ -z "$FILE_PATH" ]; then
  log_warning "File $PYTHON_FILE not found in container."
  log "Mounting file to container using mount.sh..."
  
  # Run the mount.sh script to mount the specific file
  MOUNT_CMD="$SCRIPT_DIR/mount.sh"
  if [ "$USE_NAMED_VOLUMES" = "true" ]; then
    MOUNT_CMD="$MOUNT_CMD --named-volumes"
  fi
  $MOUNT_CMD --type $FILE_TYPE "$PYTHON_FILE"
  
  # Search for the file again
  FILE_PATH=$(docker exec $CONTAINER_NAME find $CONTAINER_DIR -name $(basename $PYTHON_FILE) -type f 2>/dev/null)
  
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