#!/bin/bash

# --- Basic setup ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_DIR/dev/src"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common.sh"

# --- Usage information ---
show_usage() {
  echo "Usage: $0 [--all] [--dir directory] [file1.py file2.py ...] [--prune]"
  echo ""
  echo "Remove files from Docker volumes."
  echo ""
  echo "Options:"
  echo "  file1.py file2.py     Files to remove"
  echo "  --dir directory       Directory to remove"
  echo "  --all                 Remove all files from volume"
  echo "  --prune               Prune Docker volumes"
  echo "  --help                Show this help message"
  exit 1
}

# --- Parse arguments ---
FILES=()
DIRECTORIES=()
REMOVE_ALL=false
PRUNE_VOLUMES=false

[ $# -eq 0 ] && show_usage

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      REMOVE_ALL=true
      shift
      ;;
    --dir)
      if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then
        DIRECTORIES+=("$2")
        shift 2
      else
        log_error "Error: Argument for $1 is missing"
        show_usage
      fi
      ;;
    --prune)
      PRUNE_VOLUMES=true
      shift
      ;;
    --help)
      show_usage
      shift
      ;;
    *.*)
      FILES+=("$1")
      shift
      ;;
    *)
      log_warning "Unknown argument: $1"
      shift
      ;;
  esac
done

# --- Load environment variables ---
log "Loading environment variables..."
source "$PROJECT_DIR/source/.env"
log "Environment variables loaded successfully"

# --- Check for required environment variables ---
check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_NAME" || exit 1

# Define Docker image path
DOCKER_IMAGE="gcr.io/${PROJECT_ID}/tae-tpu:v1"

# Define mount paths - must match mount.sh
CONTAINER_MOUNT_PATH="/app/mount"

# --- Function to confirm action ---
confirm_action() {
  read -p "$1 (y/n): " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

# --- Configure Docker authentication on TPU VM ---
log "Configuring Docker authentication on TPU VM..."
vmssh "gcloud auth configure-docker gcr.io --quiet"

# --- Pull Docker image if needed ---
log "Ensuring Docker image is available..."
vmssh "sudo docker pull $DOCKER_IMAGE || echo 'Using cached image'"

# --- Main execution ---
log_section "Docker Volume Cleanup"
log "- TPU Name: $TPU_NAME"
log "- Docker Image: $DOCKER_IMAGE"
log "- Volume Path: $CONTAINER_MOUNT_PATH"
log "- Remove all files: $REMOVE_ALL"
log "- Files to remove: ${FILES[*]:-None}"
log "- Directories to remove: ${DIRECTORIES[*]:-None}"
log "- Prune volumes: $PRUNE_VOLUMES"

# Create properly quoted volume mount string
VOLUME_MOUNT_STR="-v \"$SRC_DIR:$CONTAINER_MOUNT_PATH\""

# --- Check current volume state ---
log "Checking current volume state..."
VOLUME_STATE_CMD="sudo docker run --rm $VOLUME_MOUNT_STR $DOCKER_IMAGE ls -la $CONTAINER_MOUNT_PATH"
vmssh "$VOLUME_STATE_CMD"

# --- Process all file removal ---
if [ "$REMOVE_ALL" = true ]; then
  log "Removing all files from volume..."
  confirm_action "Are you sure you want to remove ALL files from the volume?" || exit 0
  
  # Use Docker to remove all files from the volume
  RM_ALL_CMD="sudo docker run --rm $VOLUME_MOUNT_STR $DOCKER_IMAGE rm -rf ${CONTAINER_MOUNT_PATH}/*"
  if vmssh "$RM_ALL_CMD"; then
    log_success "All files removed from volume"
  else
    log_error "Failed to remove all files"
    exit 1
  fi
fi

# --- Process directory removal ---
if [ ${#DIRECTORIES[@]} -gt 0 ]; then
  log "Removing specified directories..."
  
  for dir in "${DIRECTORIES[@]}"; do
    log "Checking directory: $dir"
    
    # Check if directory exists in the volume - properly escape quotes for bash command
    CHECK_DIR_CMD="sudo docker run --rm $VOLUME_MOUNT_STR $DOCKER_IMAGE bash -c '[ -d \"${CONTAINER_MOUNT_PATH}/$dir\" ] && echo EXISTS || echo NOT_EXISTS'"
    DIR_EXISTS=$(vmssh "$CHECK_DIR_CMD" | grep "EXISTS")
    
    if [[ "$DIR_EXISTS" == *"EXISTS"* ]]; then
      log "Removing directory: $dir"
      confirm_action "Are you sure you want to remove directory $dir?" || continue
      
      # Use Docker to remove the directory
      RM_DIR_CMD="sudo docker run --rm $VOLUME_MOUNT_STR $DOCKER_IMAGE rm -rf \"${CONTAINER_MOUNT_PATH}/$dir\""
      if vmssh "$RM_DIR_CMD"; then
        log_success "Directory $dir removed successfully"
      else
        log_warning "Failed to remove directory $dir"
      fi
    else
      log_warning "Directory $dir not found in volume"
    fi
  done
fi

# --- Process file removal ---
if [ ${#FILES[@]} -gt 0 ]; then
  log "Removing specified files..."
  
  for file in "${FILES[@]}"; do
    log "Checking file: $file"
    
    # Check if file exists in the volume
    CHECK_FILE_CMD="sudo docker run --rm $VOLUME_MOUNT_STR $DOCKER_IMAGE bash -c '[ -f \"${CONTAINER_MOUNT_PATH}/$file\" ] && echo EXISTS || echo NOT_EXISTS'"
    FILE_EXISTS=$(vmssh "$CHECK_FILE_CMD" | grep "EXISTS")
    
    if [[ "$FILE_EXISTS" == *"EXISTS"* ]]; then
      log "Removing file: $file"
      
      # Use Docker to remove the file
      RM_FILE_CMD="sudo docker run --rm $VOLUME_MOUNT_STR $DOCKER_IMAGE rm -f \"${CONTAINER_MOUNT_PATH}/$file\""
      if vmssh "$RM_FILE_CMD"; then
        log_success "File $file removed successfully"
      else
        log_warning "Failed to remove file $file"
      fi
    else
      log_warning "File $file not found in volume"
    fi
  done
fi

# --- Verify state after removal ---
if [ "$REMOVE_ALL" = true ] || [ ${#FILES[@]} -gt 0 ] || [ ${#DIRECTORIES[@]} -gt 0 ]; then
  log "Verifying volume state after removal..."
  
  # Check remaining files
  COUNT_CMD="sudo docker run --rm $VOLUME_MOUNT_STR $DOCKER_IMAGE bash -c 'find ${CONTAINER_MOUNT_PATH} -type f 2>/dev/null | wc -l || echo \"ERROR\"'"
  FILE_COUNT=$(vmssh "$COUNT_CMD" | tr -d '\r\n')
  
  if [[ "$FILE_COUNT" == "ERROR" ]]; then
    log_warning "Cannot access volume to verify file count"
  elif [[ "$FILE_COUNT" == "0" ]]; then
    log_success "No files remain in the volume"
  else
    log "Remaining files in volume: $FILE_COUNT"
    
    # List remaining files
    REMAINING_CMD="sudo docker run --rm $VOLUME_MOUNT_STR $DOCKER_IMAGE ls -la ${CONTAINER_MOUNT_PATH}"
    vmssh "$REMAINING_CMD"
  fi
fi

# --- Prune Docker volumes if requested ---
if [ "$PRUNE_VOLUMES" = true ]; then
  log "Pruning Docker volumes..."
  confirm_action "Are you sure you want to prune all unused Docker volumes?" || exit 0
  
  # Use Docker to prune volumes
  PRUNE_CMD="sudo docker volume prune --force"
  if vmssh "$PRUNE_CMD"; then
    log_success "Docker volumes pruned successfully"
  else
    log_error "Failed to prune Docker volumes"
  fi
fi

log_success "Volume cleanup completed successfully"
log_elapsed_time
exit 0