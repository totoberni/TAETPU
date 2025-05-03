#!/bin/bash

# --- Basic setup ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_DIR/src"
MOUNT_DIR="/tmp/tae_src"

# --- Import common functions ---
source "$PROJECT_DIR/infrastructure/utils/common.sh"

# --- Parse command-line arguments ---
MOUNT_ALL=false
SPECIFIC_FILES=()
DIRECTORIES=()

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
      -h|--help)
        echo "Usage: $0 [--all] [--dir directory] [file1.py file2.py ...]"
        echo "Mount source code to Docker container volume."
        exit 0
        ;;
      *) SPECIFIC_FILES+=("$1"); shift ;;
    esac
  done
fi

# --- Load environment variables ---
source "$PROJECT_DIR/config/.env"
check_env_vars "PROJECT_ID" || exit 1

# --- Check Docker container status ---
log_section "Docker Container Management"
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
    log "Creating new container with mounted volume..."
    
    # Make sure the mount directory exists
    mkdir -p $MOUNT_DIR
    
    # Create the container with the source directory mounted
    docker run -d \
      --name $CONTAINER_NAME \
      --privileged \
      -e PJRT_DEVICE=TPU \
      -e XLA_USE_BF16=1 \
      -e TPU_NAME=local \
      -e TPU_LOAD_LIBRARY=0 \
      -e TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so \
      -e NEXT_PLUGGABLE_DEVICE_USE_C_API=true \
      -v /dev:/dev \
      -v /lib/libtpu.so:/lib/libtpu.so \
      -v $MOUNT_DIR:/app/mount \
      eu.gcr.io/${PROJECT_ID}/tae-tpu:v1
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
log "Preparing transfer directory..."
mkdir -p $MOUNT_DIR
chmod 777 $MOUNT_DIR

# --- Create the basic directory structure in container ---
log "Creating basic directory structure in container..."
docker exec $CONTAINER_NAME mkdir -p /app/mount/src

# --- Mount operations ---
if [[ "$MOUNT_ALL" == "true" ]]; then
  log_section "Mounting All Source Files"
  log "Mounting entire src directory to Docker container"
  
  # Clean the mount directory first to ensure a fresh start
  rm -rf "$MOUNT_DIR"/*
  
  # Recursively copy all files from src directory with their full structure
  cp -r "$SRC_DIR"/* "$MOUNT_DIR/"
  
  log_success "All files transferred to mount directory"
  
else
  # Handle specific files
  if [ ${#SPECIFIC_FILES[@]} -gt 0 ]; then
    log_section "Mounting Specific Files"
    
    for file in "${SPECIFIC_FILES[@]}"; do
      src_file="$SRC_DIR/$file"
      if [ -f "$src_file" ]; then
        # Create parent directory in mount dir
        parent_dir=$(dirname "$file")
        mkdir -p "$MOUNT_DIR/$parent_dir"
        
        # Copy the file
        log "Copying $file to mount directory..."
        cp "$src_file" "$MOUNT_DIR/$file"
          
        log_success "Copied $file to mount directory"
      else
        log_warning "File $file not found in $SRC_DIR"
      fi
    done
  fi
  
  # Handle specific directories
  if [ ${#DIRECTORIES[@]} -gt 0 ]; then
    log_section "Mounting Specific Directories"
    
    for dir in "${DIRECTORIES[@]}"; do
      src_dir="$SRC_DIR/$dir"
      if [ -d "$src_dir" ]; then
        # Create directory in mount dir
        mkdir -p "$MOUNT_DIR/$dir"
        
        # Copy directory contents
        log "Copying directory $dir to mount directory..."
        cp -r "$src_dir/"* "$MOUNT_DIR/$dir/"
          
        log_success "Copied directory $dir to mount directory"
      else
        log_warning "Directory $dir not found in $SRC_DIR"
      fi
    done
  fi
  
  # If nothing specified, mount all Python files
  if [ ${#SPECIFIC_FILES[@]} -eq 0 ] && [ ${#DIRECTORIES[@]} -eq 0 ]; then
    log_section "Mounting All Python Files"
    log "Mounting all Python files to Docker container"
    
    # Find all Python files
    PYTHON_FILES=$(find "$SRC_DIR" -name "*.py")
    
    for py_file in $PYTHON_FILES; do
      # Get relative path
      rel_path=${py_file#"$SRC_DIR/"}
      parent_dir=$(dirname "$rel_path")
      
      # Create parent directory in mount dir
      mkdir -p "$MOUNT_DIR/$parent_dir"
      
      # Copy the file
      log "Copying $rel_path to mount directory..."
      cp "$py_file" "$MOUNT_DIR/$rel_path"
    done
    
    log_success "All Python files copied to mount directory"
  fi
fi

# --- Verify files are accessible from container ---
log_section "Verifying Docker Container Access"
docker exec $CONTAINER_NAME ls -la /app/mount

# --- Set appropriate permissions ---
docker exec $CONTAINER_NAME chmod -R 777 /app/mount

log_success "Files successfully mounted to Docker container at /app/mount"
exit 0