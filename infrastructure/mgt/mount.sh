#!/bin/bash

# --- Basic setup ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_DIR/src"

# --- Import common functions ---
source "$PROJECT_DIR/infrastructure/utils/common.sh"

# Initialize script
init_script "Mount Files to Docker Container"

# --- Parse command-line arguments ---
MOUNT_ALL=false
MOUNT_TYPE="src" # Default to src
SPECIFIC_FILES=()
DIRECTORIES=()
USE_NAMED_VOLUMES=false
FORCE_RECREATE=false

if [ $# -eq 0 ]; then
  MOUNT_ALL=true
else
  while [[ $# -gt 0 ]]; do
    case $1 in
      --all) MOUNT_ALL=true; shift ;;
      --dir)
        DIRECTORIES+=("$2")
        shift 2
        ;;
      --type)
        MOUNT_TYPE="$2"
        shift 2
        ;;
      --named-volumes)
        USE_NAMED_VOLUMES=true
        shift
        ;;
      --recreate)
        FORCE_RECREATE=true
        shift
        ;;
      -h|--help)
        echo "Usage: $0 [--all] [--dir directory] [--type mount_type] [--named-volumes] [--recreate] [file1.py file2.py ...]"
        echo "Mount files to Docker container volumes."
        echo ""
        echo "Options:"
        echo "  --all                Mount all files from source directory"
        echo "  --dir directory      Mount a specific directory"
        echo "  --type mount_type    Type of mount (src|datasets|models|checkpoints|logs|results)"
        echo "                       Default is 'src'"
        echo "  --named-volumes      Use Docker named volumes instead of host directories"
        echo "  --recreate           Force recreate container if it exists"
        echo "  file1.py file2.py    Mount specific files"
        exit 0
        ;;
      *) SPECIFIC_FILES+=("$1"); shift ;;
    esac
  done
fi

# --- Load environment variables ---
source "$PROJECT_DIR/config/.env"
check_env_vars "PROJECT_ID" || exit 1

# Use environment variable if set, otherwise use command line flag
[ "${USE_NAMED_VOLUMES:-false}" = "true" ] && USE_NAMED_VOLUMES=true

# --- Configure volume paths based on mount type ---
VOLUME_PREFIX="${VOLUME_PREFIX:-tae}"

case $MOUNT_TYPE in
  src)
    SOURCE_DIR="$PROJECT_DIR/src"
    MOUNT_DIR="${HOST_SRC_DIR:-/tmp/tae_src}"
    CONTAINER_DIR="/app/mount"
    VOLUME_NAME="$VOLUME_PREFIX-src"
    ;;
  datasets)
    SOURCE_DIR="$PROJECT_DIR/datasets"
    MOUNT_DIR="${HOST_DATASETS_DIR:-$PROJECT_DIR/datasets}"
    CONTAINER_DIR="/app/datasets"
    VOLUME_NAME="$VOLUME_PREFIX-datasets"
    ;;
  models)
    SOURCE_DIR="$PROJECT_DIR/models"
    MOUNT_DIR="${HOST_MODELS_DIR:-$PROJECT_DIR/models}"
    CONTAINER_DIR="/app/models"
    VOLUME_NAME="$VOLUME_PREFIX-models"
    ;;
  checkpoints)
    SOURCE_DIR="$PROJECT_DIR/checkpoints"
    MOUNT_DIR="${HOST_CHECKPOINTS_DIR:-$PROJECT_DIR/checkpoints}"
    CONTAINER_DIR="/app/checkpoints"
    VOLUME_NAME="$VOLUME_PREFIX-checkpoints"
    ;;
  logs)
    SOURCE_DIR="$PROJECT_DIR/logs"
    MOUNT_DIR="${HOST_LOGS_DIR:-$PROJECT_DIR/logs}"
    CONTAINER_DIR="/app/logs"
    VOLUME_NAME="$VOLUME_PREFIX-logs"
    ;;
  results)
    SOURCE_DIR="$PROJECT_DIR/results"
    MOUNT_DIR="${HOST_RESULTS_DIR:-$PROJECT_DIR/results}"
    CONTAINER_DIR="/app/results"
    VOLUME_NAME="$VOLUME_PREFIX-results"
    ;;
  *)
    log_error "Invalid mount type: $MOUNT_TYPE"
    echo "Valid types are: src, datasets, models, checkpoints, logs, results"
    exit 1
    ;;
esac

# Use CONTAINER_NAME from .env if defined, otherwise use the default
CONTAINER_NAME="${CONTAINER_NAME:-tae-tpu-container}"
CONTAINER_TAG="${CONTAINER_TAG:-latest}"
IMAGE_NAME="${IMAGE_NAME:-eu.gcr.io/${PROJECT_ID}/tae-tpu:v1}"

# --- Check Docker container status ---
log_section "Docker Container Management"

log "Checking if Docker container is running..."
CONTAINER_ID=$(docker ps -q -f name=$CONTAINER_NAME)

# Check for container name mismatch and fix if needed
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
  
  # Handle container recreation if requested
  if [ "$FORCE_RECREATE" = "true" ] && [ -n "$CONTAINER_ID" ]; then
    log "Force recreate requested. Stopping and removing existing container..."
    docker stop $CONTAINER_NAME
    docker rm $CONTAINER_NAME
    CONTAINER_ID=""
  fi
  
  # Check if container exists but is stopped
  STOPPED_ID=$(docker ps -aq -f name=$CONTAINER_NAME)
  if [ -n "$STOPPED_ID" ] && [ "$FORCE_RECREATE" = "false" ]; then
    log "Container exists but is stopped. Starting container..."
    docker start $CONTAINER_NAME
  else
    log "Creating new container with mounted volumes..."
    
    # Check and create Docker volumes if using named volumes
    if [ "$USE_NAMED_VOLUMES" = "true" ]; then
      log "Using Docker named volumes..."
      
      # Create volumes if they don't exist
      VOLUMES=(
        "$VOLUME_PREFIX-src"
        "$VOLUME_PREFIX-datasets"
        "$VOLUME_PREFIX-models"
        "$VOLUME_PREFIX-checkpoints"
        "$VOLUME_PREFIX-logs"
        "$VOLUME_PREFIX-results"
      )
      
      for volume in "${VOLUMES[@]}"; do
        if ! docker volume ls -q | grep -q "^$volume$"; then
          log "Creating Docker volume: $volume"
          docker volume create "$volume"
        fi
      done
      
      # Build volume mount arguments
      VOLUME_ARGS="-v $VOLUME_PREFIX-src:/app/mount \
        -v $VOLUME_PREFIX-datasets:/app/datasets \
        -v $VOLUME_PREFIX-models:/app/models \
        -v $VOLUME_PREFIX-checkpoints:/app/checkpoints \
        -v $VOLUME_PREFIX-logs:/app/logs \
        -v $VOLUME_PREFIX-results:/app/results"
    else
      log "Using host directory mounts..."
      
      # Make sure all mount directories exist
      mkdir -p "$MOUNT_DIR" "${HOST_DATASETS_DIR:-$PROJECT_DIR/datasets}" "${HOST_MODELS_DIR:-$PROJECT_DIR/models}" \
              "${HOST_CHECKPOINTS_DIR:-$PROJECT_DIR/checkpoints}" "${HOST_LOGS_DIR:-$PROJECT_DIR/logs}" "${HOST_RESULTS_DIR:-$PROJECT_DIR/results}"
      
      # Build volume mount arguments
      VOLUME_ARGS="-v ${HOST_SRC_DIR:-/tmp/tae_src}:/app/mount \
        -v ${HOST_DATASETS_DIR:-$PROJECT_DIR/datasets}:/app/datasets \
        -v ${HOST_MODELS_DIR:-$PROJECT_DIR/models}:/app/models \
        -v ${HOST_CHECKPOINTS_DIR:-$PROJECT_DIR/checkpoints}:/app/checkpoints \
        -v ${HOST_LOGS_DIR:-$PROJECT_DIR/logs}:/app/logs \
        -v ${HOST_RESULTS_DIR:-$PROJECT_DIR/results}:/app/results"
    fi
    
    # Create the container with the appropriate volumes
    log "Creating container $CONTAINER_NAME from image ${IMAGE_NAME}..."
    # First try with the IMAGE_NAME
    if ! docker run -d \
      --name $CONTAINER_NAME \
      --privileged \
      --network=host \
      -e PJRT_DEVICE=TPU \
      -e XLA_USE_BF16=1 \
      -e TPU_NAME=local \
      -e TPU_LOAD_LIBRARY=0 \
      -e TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so \
      -e NEXT_PLUGGABLE_DEVICE_USE_C_API=true \
      -v /dev:/dev \
      -v /lib/libtpu.so:/lib/libtpu.so \
      -v /usr/share/tpu/:/usr/share/tpu/ \
      $VOLUME_ARGS \
      "${IMAGE_NAME}"; then
      
      log_warning "Failed to create container with IMAGE_NAME. Trying with alternative name..."
      
      # Try with the CONTAINER_NAME tag
      if ! docker run -d \
        --name $CONTAINER_NAME \
        --privileged \
        --network=host \
        -e PJRT_DEVICE=TPU \
        -e XLA_USE_BF16=1 \
        -e TPU_NAME=local \
        -e TPU_LOAD_LIBRARY=0 \
        -e TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so \
        -e NEXT_PLUGGABLE_DEVICE_USE_C_API=true \
        -v /dev:/dev \
        -v /lib/libtpu.so:/lib/libtpu.so \
        -v /usr/share/tpu/:/usr/share/tpu/ \
        $VOLUME_ARGS \
        "${CONTAINER_NAME}:${CONTAINER_TAG}"; then
        
        log_error "Failed to create container. Please check image name and availability."
        exit 1
      fi
    fi
  fi
  
  # Check again to confirm container is running
  CONTAINER_ID=$(docker ps -q -f name=$CONTAINER_NAME)
  if [ -z "$CONTAINER_ID" ]; then
    log_error "Failed to start Docker container"
    exit 1
  fi
fi

log_success "Container $CONTAINER_NAME is running with ID: $CONTAINER_ID"

# --- Prepare mount directory ---
if [ "$USE_NAMED_VOLUMES" = "false" ]; then
  log "Preparing $MOUNT_TYPE directory in host path..."
  mkdir -p "$MOUNT_DIR"
  chmod 777 "$MOUNT_DIR"
fi

# --- Create the basic directory structure in container ---
log "Creating basic directory structure in container..."
docker exec $CONTAINER_NAME mkdir -p "$CONTAINER_DIR"

# --- Mount operations ---
if [[ "$MOUNT_ALL" == "true" ]]; then
  log_section "Mounting All $MOUNT_TYPE Files"
  log "Mounting entire $MOUNT_TYPE directory to Docker container at $CONTAINER_DIR"
  
  # Make sure source directory exists
  if [ ! -d "$SOURCE_DIR" ]; then
    log "Creating source directory: $SOURCE_DIR"
    mkdir -p "$SOURCE_DIR"
  fi
  
  if [ "$USE_NAMED_VOLUMES" = "true" ]; then
    # For named volumes, use a temporary directory to stage files
    TEMP_DIR=$(mktemp -d)
    log "Using temporary directory for staging: $TEMP_DIR"
    
    # Copy all files to the temporary directory
    cp -r "$SOURCE_DIR/"* "$TEMP_DIR/" 2>/dev/null || true
    
    # Copy from temporary directory to container volume
    docker cp "$TEMP_DIR/." "$CONTAINER_NAME:$CONTAINER_DIR/"
    
    # Clean up temporary directory
    rm -rf "$TEMP_DIR"
  else
    # Clean the mount directory first to ensure a fresh start
    rm -rf "$MOUNT_DIR"/*
    
    # Recursively copy all files from source directory with their full structure
    cp -r "$SOURCE_DIR"/* "$MOUNT_DIR/" 2>/dev/null || true
  fi
  
  log_success "All files transferred to $CONTAINER_DIR"
  
else
  # Handle specific files
  if [ ${#SPECIFIC_FILES[@]} -gt 0 ]; then
    log_section "Mounting Specific Files"
    
    for file in "${SPECIFIC_FILES[@]}"; do
      src_file="$SOURCE_DIR/$file"
      if [ -f "$src_file" ]; then
        if [ "$USE_NAMED_VOLUMES" = "true" ]; then
          # For named volumes, copy directly to the container
          parent_dir=$(dirname "$file")
          docker exec $CONTAINER_NAME mkdir -p "$CONTAINER_DIR/$parent_dir"
          
          # Use temporary file for transfer
          TEMP_FILE=$(mktemp)
          cp "$src_file" "$TEMP_FILE"
          docker cp "$TEMP_FILE" "$CONTAINER_NAME:$CONTAINER_DIR/$file"
          rm "$TEMP_FILE"
        else
          # Create parent directory in mount dir
          parent_dir=$(dirname "$file")
          mkdir -p "$MOUNT_DIR/$parent_dir"
          
          # Copy the file
          cp "$src_file" "$MOUNT_DIR/$file"
        fi
          
        log_success "Copied $file to $CONTAINER_DIR"
      else
        log_warning "File $file not found in $SOURCE_DIR"
      fi
    done
  fi
  
  # Handle specific directories
  if [ ${#DIRECTORIES[@]} -gt 0 ]; then
    log_section "Mounting Specific Directories"
    
    for dir in "${DIRECTORIES[@]}"; do
      src_dir="$SOURCE_DIR/$dir"
      if [ -d "$src_dir" ]; then
        if [ "$USE_NAMED_VOLUMES" = "true" ]; then
          # For named volumes, copy directly to the container
          docker exec $CONTAINER_NAME mkdir -p "$CONTAINER_DIR/$dir"
          
          # Use temporary directory for transfer
          TEMP_DIR=$(mktemp -d)
          cp -r "$src_dir/"* "$TEMP_DIR/" 2>/dev/null || true
          docker cp "$TEMP_DIR/." "$CONTAINER_NAME:$CONTAINER_DIR/$dir/"
          rm -rf "$TEMP_DIR"
        else
          # Create directory in mount dir
          mkdir -p "$MOUNT_DIR/$dir"
          
          # Copy directory contents
          cp -r "$src_dir/"* "$MOUNT_DIR/$dir/" 2>/dev/null || true
        fi
          
        log_success "Copied directory $dir to $CONTAINER_DIR"
      else
        log_warning "Directory $dir not found in $SOURCE_DIR"
        
        # Create the directory if it doesn't exist
        mkdir -p "$src_dir"
        
        if [ "$USE_NAMED_VOLUMES" = "true" ]; then
          docker exec $CONTAINER_NAME mkdir -p "$CONTAINER_DIR/$dir"
        else
          mkdir -p "$MOUNT_DIR/$dir"
        fi
        
        log "Created empty directory: $dir"
      fi
    done
  fi
  
  # If nothing specified, mount all Python files (only for src type)
  if [ ${#SPECIFIC_FILES[@]} -eq 0 ] && [ ${#DIRECTORIES[@]} -eq 0 ] && [ "$MOUNT_TYPE" == "src" ]; then
    log_section "Mounting All Python Files"
    log "Mounting all Python files to Docker container"
    
    # Find all Python files
    PYTHON_FILES=$(find "$SOURCE_DIR" -name "*.py" 2>/dev/null || echo "")
    
    for py_file in $PYTHON_FILES; do
      # Get relative path
      rel_path=${py_file#"$SOURCE_DIR/"}
      parent_dir=$(dirname "$rel_path")
      
      if [ "$USE_NAMED_VOLUMES" = "true" ]; then
        # For named volumes, copy directly to the container
        docker exec $CONTAINER_NAME mkdir -p "$CONTAINER_DIR/$parent_dir"
        
        # Use temporary file for transfer
        TEMP_FILE=$(mktemp)
        cp "$py_file" "$TEMP_FILE"
        docker cp "$TEMP_FILE" "$CONTAINER_NAME:$CONTAINER_DIR/$rel_path"
        rm "$TEMP_FILE"
      else
        # Create parent directory in mount dir
        mkdir -p "$MOUNT_DIR/$parent_dir"
        
        # Copy the file
        cp "$py_file" "$MOUNT_DIR/$rel_path"
      fi
      
      log_success "Copied $rel_path to $CONTAINER_DIR"
    done
  fi
fi

# --- Verify files are accessible from container ---
log_section "Verifying Docker Container Access"
docker exec $CONTAINER_NAME ls -la "$CONTAINER_DIR"

# --- Set appropriate permissions ---
docker exec $CONTAINER_NAME chmod -R 777 "$CONTAINER_DIR"

log_success "Files successfully mounted to Docker container at $CONTAINER_DIR"
exit 0