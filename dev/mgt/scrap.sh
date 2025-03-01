#!/bin/bash

# --- DETERMINE SCRIPT AND PROJECT DIRECTORIES ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- DEFINE PATH CONSTANTS - Use these consistently across all scripts ---
TPU_HOST_PATH="/tmp/dev/src"
DOCKER_CONTAINER_PATH="/app/dev/src"

# --- IMPORT COMMON FUNCTIONS ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

# --- HELPER FUNCTIONS ---
show_usage() {
  echo "Usage: $0 [-a|--all] [file1.py file2.sh ...] [--utils] [--auto-confirm]"
  echo ""
  echo "Remove specified files from the TPU VM."
  echo ""
  echo "Options:"
  echo "  -a, --all         Remove all files from TPU VM"
  echo "  --utils           Remove the utils directory"
  echo "  --auto-confirm    Don't ask for confirmation (useful for scripts)"
  echo "  -h, --help        Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 example.py               # Remove example.py"
  echo "  $0 model.py train.py        # Remove multiple files"
  echo "  $0 --all                    # Remove all files"
  echo "  $0 --utils                  # Remove only the utils directory"
  echo ""
  echo "Note: This script can be run from any directory in the codebase"
  exit 1
}

# --- MAIN SCRIPT ---
# Parse command line arguments
SCRAP_ALL=false
SCRAP_UTILS=false
AUTO_CONFIRM=false
FILES_TO_SCRAP=()

if [ $# -eq 0 ]; then
  show_usage
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    -a|--all)
      SCRAP_ALL=true
      shift # shift past the argument
      ;;
    --utils)
      SCRAP_UTILS=true
      shift # shift past the argument
      ;;
    --auto-confirm)
      AUTO_CONFIRM=true
      shift # shift past the argument
      ;;
    -h|--help)
      show_usage
      ;;
    *)
      # Assume this is a file to scrap
      FILES_TO_SCRAP+=("$1")
      shift # shift past the argument
      ;;
  esac
done

log 'Starting TPU development environment cleanup process...'

log 'Loading environment variables...'
source "$PROJECT_DIR/source/.env"
log 'Environment variables loaded successfully'

# Validate required environment variables
check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_NAME"

log "Configuration:"
log "- Project ID: $PROJECT_ID"
log "- TPU Zone: $TPU_ZONE"
log "- TPU Name: $TPU_NAME"
log "- TPU Host Path: $TPU_HOST_PATH"

# Determine which files to scrap
if [[ "$SCRAP_ALL" == "true" ]]; then
  log "Preparing to remove all files from TPU VM..."
  
  # Get file list from TPU VM
  log "Getting file list from TPU VM..."
  file_list=$(ssh_with_timeout "find ${TPU_HOST_PATH} -maxdepth 1 -type f -not -path '*/\.*' -exec basename {} \;" 20)
  
  if [ -z "$file_list" ]; then
    log_warning "No files found on TPU VM"
    FILES_TO_SCRAP=()
  else
    # Convert the newline-separated list to an array
    readarray -t FILES_TO_SCRAP <<< "$file_list"
    log "Found ${#FILES_TO_SCRAP[@]} files to remove"
  fi
  
  # Always scrap utils directory with --all flag
  SCRAP_UTILS=true
fi

# Ask for confirmation if not auto-confirmed
if [[ "$AUTO_CONFIRM" == "false" ]]; then
  if [[ "$SCRAP_ALL" == "true" ]]; then
    read -p "This will remove ALL files and the utils directory from the TPU VM. Continue? (y/n) " confirm
  elif [[ "$SCRAP_UTILS" == "true" && ${#FILES_TO_SCRAP[@]} -gt 0 ]]; then
    read -p "This will remove ${#FILES_TO_SCRAP[@]} files and the utils directory from the TPU VM. Continue? (y/n) " confirm
  elif [[ "$SCRAP_UTILS" == "true" ]]; then
    read -p "This will remove the utils directory from the TPU VM. Continue? (y/n) " confirm
  elif [[ ${#FILES_TO_SCRAP[@]} -gt 0 ]]; then
    read -p "This will remove ${#FILES_TO_SCRAP[@]} files from the TPU VM. Continue? (y/n) " confirm
  else
    log_error "No files or directories specified to remove"
    exit 1
  fi
  
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log "Operation cancelled by user"
    exit 0
  fi
fi

# Remove each file from the TPU VM
if [[ ${#FILES_TO_SCRAP[@]} -gt 0 ]]; then
  log "Removing files from TPU VM..."
  for file in "${FILES_TO_SCRAP[@]}"; do
    log "- Removing $file"
    ssh_with_timeout "if [[ -f ${TPU_HOST_PATH}/${file} ]]; then rm ${TPU_HOST_PATH}/${file} && echo 'removed'; else echo 'not_found'; fi" | grep -q "removed"
    if [ $? -eq 0 ]; then
      log_success "Successfully removed $file"
    else
      log_warning "File $file not found on TPU VM or couldn't be removed"
    fi
  done
else
  log "No files to remove"
fi

# Remove utils directory if requested
if [[ "$SCRAP_UTILS" == "true" ]]; then
  log "Removing utils directory from TPU VM..."
  ssh_with_timeout "if [[ -d ${TPU_HOST_PATH}/utils ]]; then rm -rf ${TPU_HOST_PATH}/utils && echo 'removed'; else echo 'not_found'; fi" | grep -q "removed"
  if [ $? -eq 0 ]; then
    log_success "Successfully removed utils directory"
  else
    log_warning "Utils directory not found or couldn't be removed"
  fi
fi

log_success "Cleanup process completed successfully."

# List remaining files for verification
log "Verifying TPU VM state..."
ssh_with_timeout "ls -la ${TPU_HOST_PATH}/" || log_warning "Failed to list files, but cleanup process may have succeeded"

log "To mount new files, use: ./dev/mgt/mount.sh [filename.py]"
log "To run mounted files, use: ./dev/mgt/run.sh [filename.py]"