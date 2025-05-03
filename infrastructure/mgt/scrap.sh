#!/bin/bash

# --- Basic setup ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/infrastructure/utils/common.sh"

# --- Parse command-line arguments ---
SCRAP_ALL=false
SCRAP_DIR=""
SPECIFIC_FILES=()

if [ $# -eq 0 ]; then
  echo "Usage: $0 [--all] [--dir directory] [file1.py file2.py ...]"
  echo "Remove files from Docker container volume."
  exit 0
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    --all) SCRAP_ALL=true; shift ;;
    --dir)
      SCRAP_DIR="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--all] [--dir directory] [file1.py file2.py ...]"
      echo "Remove files from Docker container volume."
      echo ""
      echo "Options:"
      echo "  --all               Remove all files and directories"
      echo "  --dir DIRECTORY     Remove a specific directory and its contents"
      echo "  file1.py file2.py   Remove specific files"
      exit 0
      ;;
    *) SPECIFIC_FILES+=("$1"); shift ;;
  esac
done

# --- Load environment variables ---
source "$PROJECT_DIR/config/.env"
check_env_vars "PROJECT_ID" || exit 1

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
  if ! confirm_delete "ALL files and directories in the container"; then
    log_warning "Operation cancelled by user"
    exit 0
  fi
  
  # Remove everything under /app/mount
  log "Removing all files and directories from container..."
  docker exec $CONTAINER_NAME rm -rf /app/mount/*
  
  # Recreate just the base /app/mount directory to maintain mount point
  docker exec $CONTAINER_NAME mkdir -p /app/mount
  
  log_success "All files and directories removed from container"
  
elif [[ -n "$SCRAP_DIR" ]]; then
  log_section "Removing Directory"
  
  # Check if directory exists in container
  if ! docker exec $CONTAINER_NAME test -d /app/mount/$SCRAP_DIR; then
    log_warning "Directory /app/mount/$SCRAP_DIR not found in container"
    exit 1
  fi
  
  # Confirm deletion with user
  if ! confirm_delete "directory $SCRAP_DIR and all its contents"; then
    log_warning "Operation cancelled by user"
    exit 0
  fi
  
  # Remove the directory
  log "Removing directory $SCRAP_DIR from container..."
  docker exec $CONTAINER_NAME rm -rf /app/mount/$SCRAP_DIR
  
  log_success "Directory $SCRAP_DIR removed from container"
  
elif [ ${#SPECIFIC_FILES[@]} -gt 0 ]; then
  log_section "Removing Specific Files"
  
  # Confirm deletion with user
  if ! confirm_delete "the specified files"; then
    log_warning "Operation cancelled by user"
    exit 0
  fi
  
  # Delete each file
  for file in "${SPECIFIC_FILES[@]}"; do
    if docker exec $CONTAINER_NAME find /app/mount -name $(basename $file) -type f | grep -q .; then
      log "Removing file $file from container..."
      docker exec $CONTAINER_NAME find /app/mount -name $(basename $file) -type f -delete
      log_success "Removed $file from container"
    else
      log_warning "File $file not found in container"
    fi
  done
  
  log_success "File removal complete"
fi

# --- Verify removal ---
log_section "Container File Status"
log "Current files in /app/mount:"
docker exec $CONTAINER_NAME find /app/mount -type f | sort

exit 0