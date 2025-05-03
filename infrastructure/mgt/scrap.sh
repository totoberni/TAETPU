#!/bin/bash

# --- Basic setup ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/infrastructure/utils/common.sh"

# Initialize script
init_script "Remove Files from Docker Container"

# --- Parse command-line arguments ---
SCRAP_ALL=false
SCRAP_DIR=""
SCRAP_TYPE="src" # Default to src
SPECIFIC_FILES=()
USE_NAMED_VOLUMES=false

if [ $# -eq 0 ]; then
  echo "Usage: $0 [--all] [--dir directory] [--type scrap_type] [--named-volumes] [file1.py file2.py ...]"
  echo "Remove files from Docker container volumes."
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    --all) SCRAP_ALL=true; shift ;;
    --dir)
      SCRAP_DIR="$2"
      shift 2
      ;;
    --type)
      SCRAP_TYPE="$2"
      shift 2
      ;;
    --named-volumes)
      USE_NAMED_VOLUMES=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--all] [--dir directory] [--type scrap_type] [--named-volumes] [file1.py file2.py ...]"
      echo "Remove files from Docker container volumes."
      echo ""
      echo "Options:"
      echo "  --all               Remove all files and directories"
      echo "  --dir DIRECTORY     Remove a specific directory and its contents"
      echo "  --type scrap_type   Type of files to scrap (src|datasets|models|checkpoints|logs|results)"
      echo "                      Default is 'src'"
      echo "  --named-volumes     Use Docker named volumes instead of host directories"
      echo "  file1.py file2.py   Remove specific files"
      exit 0
      ;;
    *) SPECIFIC_FILES+=("$1"); shift ;;
  esac
done

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

# --- Configure container directory based on scrap type ---
case $SCRAP_TYPE in
  src)
    SOURCE_DIR="$PROJECT_DIR/src"
    CONTAINER_DIR="/app/mount"
    MOUNT_DIR="${HOST_SRC_DIR:-/tmp/tae_src}"
    VOLUME_NAME="$VOLUME_PREFIX-src"
    ;;
  datasets)
    SOURCE_DIR="$PROJECT_DIR/datasets"
    CONTAINER_DIR="/app/datasets"
    MOUNT_DIR="${HOST_DATASETS_DIR:-$PROJECT_DIR/datasets}"
    VOLUME_NAME="$VOLUME_PREFIX-datasets"
    ;;
  models)
    SOURCE_DIR="$PROJECT_DIR/models"
    CONTAINER_DIR="/app/models"
    MOUNT_DIR="${HOST_MODELS_DIR:-$PROJECT_DIR/models}"
    VOLUME_NAME="$VOLUME_PREFIX-models"
    ;;
  checkpoints)
    SOURCE_DIR="$PROJECT_DIR/checkpoints"
    CONTAINER_DIR="/app/checkpoints"
    MOUNT_DIR="${HOST_CHECKPOINTS_DIR:-$PROJECT_DIR/checkpoints}"
    VOLUME_NAME="$VOLUME_PREFIX-checkpoints"
    ;;
  logs)
    SOURCE_DIR="$PROJECT_DIR/logs"
    CONTAINER_DIR="/app/logs"
    MOUNT_DIR="${HOST_LOGS_DIR:-$PROJECT_DIR/logs}"
    VOLUME_NAME="$VOLUME_PREFIX-logs"
    ;;
  results)
    SOURCE_DIR="$PROJECT_DIR/results"
    CONTAINER_DIR="/app/results"
    MOUNT_DIR="${HOST_RESULTS_DIR:-$PROJECT_DIR/results}"
    VOLUME_NAME="$VOLUME_PREFIX-results"
    ;;
  *)
    log_error "Invalid scrap type: $SCRAP_TYPE"
    echo "Valid types are: src, datasets, models, checkpoints, logs, results"
    exit 1
    ;;
esac

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
    log_error "Container does not exist. Nothing to clean up."
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

# --- Handle deletion operations ---
if [[ "$SCRAP_ALL" == "true" ]]; then
  log_section "Removing All Files and Directories"
  
  # Confirm deletion with user
  if ! confirm_delete "ALL files and directories in the $SCRAP_TYPE volume"; then
    log_warning "Operation cancelled by user"
    exit 0
  fi
  
  # Remove everything under the specified container directory
  log "Removing all files and directories from $SCRAP_TYPE volume..."
  docker exec $CONTAINER_NAME rm -rf ${CONTAINER_DIR}/*
  
  # Recreate just the base directory to maintain mount point
  docker exec $CONTAINER_NAME mkdir -p $CONTAINER_DIR
  
  # If using host directory, also clean it
  if [ "$USE_NAMED_VOLUMES" = "false" ] && [ -d "$MOUNT_DIR" ]; then
    log "Cleaning host directory $MOUNT_DIR..."
    rm -rf "${MOUNT_DIR:?}"/* # Extra safety check to prevent rm -rf /
    mkdir -p "$MOUNT_DIR"
  fi
  
  log_success "All files and directories removed from $SCRAP_TYPE volume"
  
elif [[ -n "$SCRAP_DIR" ]]; then
  log_section "Removing Directory"
  
  # Check if directory exists in container
  if ! docker exec $CONTAINER_NAME test -d ${CONTAINER_DIR}/$SCRAP_DIR; then
    log_warning "Directory ${CONTAINER_DIR}/$SCRAP_DIR not found in container"
    exit 1
  fi
  
  # Confirm deletion with user
  if ! confirm_delete "directory $SCRAP_DIR and all its contents from $SCRAP_TYPE volume"; then
    log_warning "Operation cancelled by user"
    exit 0
  fi
  
  # Remove the directory from container
  log "Removing directory $SCRAP_DIR from $SCRAP_TYPE volume..."
  docker exec $CONTAINER_NAME rm -rf ${CONTAINER_DIR}/$SCRAP_DIR
  
  # If using host directory, also remove from host
  if [ "$USE_NAMED_VOLUMES" = "false" ] && [ -d "$MOUNT_DIR/$SCRAP_DIR" ]; then
    log "Removing directory from host: $MOUNT_DIR/$SCRAP_DIR"
    rm -rf "$MOUNT_DIR/$SCRAP_DIR"
  fi
  
  log_success "Directory $SCRAP_DIR removed from $SCRAP_TYPE volume"
  
elif [ ${#SPECIFIC_FILES[@]} -gt 0 ]; then
  log_section "Removing Specific Files"
  
  # Confirm deletion with user
  if ! confirm_delete "the specified files from $SCRAP_TYPE volume"; then
    log_warning "Operation cancelled by user"
    exit 0
  fi
  
  # Delete each file
  for file in "${SPECIFIC_FILES[@]}"; do
    # Find in container
    if docker exec $CONTAINER_NAME find ${CONTAINER_DIR} -name $(basename $file) -type f | grep -q .; then
      log "Removing file $file from container..."
      docker exec $CONTAINER_NAME find ${CONTAINER_DIR} -name $(basename $file) -type f -delete
      log_success "Removed $file from container"
    else
      log_warning "File $file not found in container"
    fi
    
    # If using host directory, also remove from host
    if [ "$USE_NAMED_VOLUMES" = "false" ]; then
      host_file="$MOUNT_DIR/$file"
      if [ -f "$host_file" ]; then
        log "Removing file from host: $host_file"
        rm -f "$host_file"
        log_success "Removed $file from host"
      fi
    fi
  done
  
  log_success "File removal complete"
fi

# --- Verify removal ---
log_section "Container File Status"
log "Current files in $CONTAINER_DIR:"
docker exec $CONTAINER_NAME find $CONTAINER_DIR -type f | sort

# --- If using host directories, also check host ---
if [ "$USE_NAMED_VOLUMES" = "false" ]; then
  log_section "Host Directory Status"
  log "Current files in $MOUNT_DIR:"
  find "$MOUNT_DIR" -type f | sort
fi

exit 0