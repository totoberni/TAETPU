#!/bin/bash

# --- Basic setup ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MOUNT_PATH="/tmp/app/mount"
DOCKER_IMAGE=${DOCKER_IMAGE:-"tpu-dev-image"}
TPU_LIB_PATH=${TPU_LIB_PATH:-"/lib/libtpu.so"}

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common.sh"

# Initialize script with name
init_script "TPU Resource Cleanup"

# --- Usage information ---
show_usage() {
  echo "Usage: $0 [--all] [--dir directory] [file1.py file2.py ...] [--prune]"
  echo ""
  echo "Remove files from Docker mounted directory and optionally prune Docker volumes."
  echo ""
  echo "Options:"
  echo "  file1.py file2.py     Files to remove"
  echo "  --dir directory       Directory to remove"
  echo "  --all                 Remove all files from mount directory"
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

# --- Check for required environment variables ---
load_env_vars "$PROJECT_DIR/source/.env"

# --- Function to confirm action ---
confirm_action() {
  read -p "$1 (y/n): " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

# --- Docker execution helper ---
run_docker_cmd() {
  local CMD="$1"
  
  DOCKER_CMD=$(generate_docker_cmd "$DOCKER_IMAGE" "$TPU_LIB_PATH" "$CMD")
  log "Running Docker command..."
  eval "$DOCKER_CMD"
  return $?
}

# --- Main execution ---
log_section "TPU Resource Cleanup"
log "- Docker Image: $DOCKER_IMAGE"
log "- Mount path: $MOUNT_PATH"
log "- Remove all files: $REMOVE_ALL"
log "- Files to remove: ${FILES[*]:-None}"
log "- Directories to remove: ${DIRECTORIES[*]:-None}"
log "- Prune volumes: $PRUNE_VOLUMES"

# Get current list of files in the mounted directory
log "Checking current mounted files..."
FILE_LIST=$(run_docker_cmd "ls -la $MOUNT_PATH 2>/dev/null || echo 'EMPTY'")

# Check if the directory exists or is empty
if [[ "$FILE_LIST" == *"EMPTY"* ]]; then
  log_warning "Mount directory $MOUNT_PATH does not exist or is empty"
  
  # Create directory if it doesn't exist
  log "Creating mount directory..."
  run_docker_cmd "mkdir -p $MOUNT_PATH"
else
  log_success "Mount directory exists:"
  echo "$FILE_LIST"
fi

# Process file removal
if [ "$REMOVE_ALL" = true ]; then
  # Remove all files if --all is specified
  log "Removing all files from $MOUNT_PATH..."
  confirm_action "Are you sure you want to remove ALL files?" || exit 0
  
  # Try to remove all files
  run_docker_cmd "rm -rf $MOUNT_PATH/* && echo 'All files removed successfully'"
  if [ $? -eq 0 ]; then
    log_success "All files removed from mount directory"
  else
    log_error "Failed to remove all files"
    exit 1
  fi
fi

# Remove specified directories
if [ ${#DIRECTORIES[@]} -gt 0 ]; then
  log "Removing ${#DIRECTORIES[@]} directory/directories..."
  
  for dir in "${DIRECTORIES[@]}"; do
    # Check if directory exists
    DIR_CHECK=$(run_docker_cmd "[ -d $MOUNT_PATH/$dir ] && echo 'EXISTS' || echo 'NOT_EXISTS'")
    
    if [[ "$DIR_CHECK" == *"EXISTS"* ]]; then
      log "Removing directory $dir..."
      confirm_action "Are you sure you want to remove directory $dir?" || continue
      
      run_docker_cmd "rm -rf $MOUNT_PATH/$dir"
      if [ $? -eq 0 ]; then
        log_success "Removed directory $dir"
      else
        log_warning "Failed to remove directory $dir"
      fi
    else
      log_warning "Directory $dir not found in $MOUNT_PATH"
    fi
  done
fi

# Remove specified files
if [ ${#FILES[@]} -gt 0 ]; then
  log "Removing ${#FILES[@]} file(s)..."
  
  for file in "${FILES[@]}"; do
    # Check if file exists
    FILE_CHECK=$(run_docker_cmd "[ -f $MOUNT_PATH/$file ] && echo 'EXISTS' || echo 'NOT_EXISTS'")
    
    if [[ "$FILE_CHECK" == *"EXISTS"* ]]; then
      log "Removing file $file..."
      
      run_docker_cmd "rm -f $MOUNT_PATH/$file"
      if [ $? -eq 0 ]; then
        log_success "Removed file $file"
      else
        log_warning "Failed to remove file $file"
      fi
    else
      log_warning "File $file not found in $MOUNT_PATH"
    fi
  done
fi

# Verify state after removal
if [ "$REMOVE_ALL" = true ] || [ ${#FILES[@]} -gt 0 ] || [ ${#DIRECTORIES[@]} -gt 0 ]; then
  log "Verifying current state after removal..."
  
  # Count remaining files
  COUNT_RESULT=$(run_docker_cmd "find $MOUNT_PATH -type f 2>/dev/null | wc -l || echo 'ERROR'")
  
  if [[ "$COUNT_RESULT" == "ERROR" ]]; then
    log_warning "Cannot access mount directory to verify"
  elif [[ "$COUNT_RESULT" == "0" ]]; then
    log_success "No files remain in the mount directory"
  else
    log "Some files remain in the mount directory. File count: $COUNT_RESULT"
    
    # Show remaining files
    REMAINING_FILES=$(run_docker_cmd "ls -la $MOUNT_PATH 2>/dev/null || echo 'CANNOT_ACCESS'")
    if [[ "$REMAINING_FILES" != *"CANNOT_ACCESS"* ]]; then
      echo "$REMAINING_FILES"
    else
      log_warning "Cannot access mount directory to list remaining files"
    fi
  fi
fi

# Prune Docker volumes if requested
if [ "$PRUNE_VOLUMES" = true ]; then
  log "Pruning Docker volumes..."
  confirm_action "Are you sure you want to prune all unused Docker volumes?" || exit 0
  
  docker volume prune --force
  if [ $? -eq 0 ]; then
    log_success "Docker volumes pruned successfully"
  else
    log_error "Failed to prune Docker volumes"
  fi
fi

log_success "Cleanup completed successfully"
log_elapsed_time
exit 0
