#!/bin/bash

# --- DETERMINE SCRIPT AND PROJECT DIRECTORIES ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- IMPORT COMMON FUNCTIONS ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

show_usage() {
  echo "Usage: $0 [filename1.py filename2.py ...] [--utils] [--all] [--auto-confirm]"
  echo ""
  echo "Remove file(s) from the TPU VM and optionally clean up Docker volumes."
  echo ""
  echo "Arguments:"
  echo "  filename1.py filename2.py   Files to remove from TPU VM (must be in /dev/src or /dev/src/utils)"
  echo "  --utils                    Remove the utils directory"
  echo "  --all                      Remove all mounted files and directories"
  echo "  --auto-confirm             Skip confirmation prompts"
  echo ""
  echo "Examples:"
  echo "  $0 example.py               # Remove a single file"
  echo "  $0 --utils                  # Remove only the utils directory"
  echo "  $0 example.py train.py      # Remove multiple files"
  echo "  $0 --all                    # Remove everything in the dev directory"
  exit 1
}

# Function to load mount information from temp file
load_mount_info() {
  MOUNT_INFO_FILE="$PROJECT_DIR/source/.mount_info.tmp"
  if [[ -f "$MOUNT_INFO_FILE" ]]; then
    log "Found mount information file"
    source "$MOUNT_INFO_FILE"
    return 0
  else
    log_warning "No mount information file found. Will rely on command arguments."
    return 1
  fi
}

# Main script starts here
if [ $# -eq 0 ]; then
  show_usage
fi

log 'Loading environment variables...'
source "$PROJECT_DIR/source/.env"
log 'Environment variables loaded successfully'

# Validate required environment variables
check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_NAME"

# Parse arguments
FILES_TO_REMOVE=()
REMOVE_UTILS=false
REMOVE_ALL=false
AUTO_CONFIRM=false

for arg in "$@"; do
  if [[ "$arg" == "--utils" ]]; then
    REMOVE_UTILS=true
  elif [[ "$arg" == "--all" ]]; then
    REMOVE_ALL=true
  elif [[ "$arg" == "--auto-confirm" ]]; then
    AUTO_CONFIRM=true
  elif [[ "$arg" == *.py ]]; then
    FILES_TO_REMOVE+=("$arg")
  else
    log_warning "Unknown argument: $arg"
  fi
done

# Load mount information if available
load_mount_info

# Target directory on TPU VM
TARGET_DIR="/tmp/dev/src"

# Check if development directory exists
if ! ssh_with_timeout "test -d ${TARGET_DIR} && echo 'exists'" | grep -q "exists"; then
  log_warning "Directory ${TARGET_DIR} does not exist on TPU VM"
  if [[ ${#FILES_TO_REMOVE[@]} -eq 0 && "$REMOVE_UTILS" == "false" && "$REMOVE_ALL" == "false" ]]; then
    log_warning "Nothing to clean, exiting"
    exit 0
  fi
fi

# Handle --all flag
if [[ "$REMOVE_ALL" == "true" ]]; then
  if [[ "$AUTO_CONFIRM" != "true" ]]; then
    read -p "Are you sure you want to remove ALL mounted files? (y/n): " CONFIRM
    if [[ "$CONFIRM" != "y" ]]; then
      log "Operation cancelled by user"
      exit 0
    fi
  fi
  
  log "Removing all files from ${TARGET_DIR}..."
  ssh_with_timeout "if [ -d ${TARGET_DIR} ]; then rm -rf ${TARGET_DIR}/* 2>/dev/null || true; fi"
  log_success "All files removed from TPU VM"
  
  # Prune Docker volumes
  log "Pruning Docker volumes..."
  ssh_with_timeout "docker volume prune -f" 15
  log_success "Docker volumes pruned"
  
  exit 0
fi

# Handle utils directory removal
if [[ "$REMOVE_UTILS" == "true" ]]; then
  log "Removing utils directory from TPU VM..."
  ssh_with_timeout "if [ -d ${TARGET_DIR}/utils ]; then rm -rf ${TARGET_DIR}/utils 2>/dev/null || true; fi"
  log_success "Utils directory removed from TPU VM"
fi

# Remove individual files
if [[ ${#FILES_TO_REMOVE[@]} -gt 0 ]]; then
  log "Removing ${#FILES_TO_REMOVE[@]} file(s) from TPU VM..."
  
  for file in "${FILES_TO_REMOVE[@]}"; do
    # First check in the main dev directory
    if ssh_with_timeout "test -f ${TARGET_DIR}/${file} && echo 'exists'" | grep -q "exists"; then
      log "Removing ${file} from main directory..."
      ssh_with_timeout "rm -f ${TARGET_DIR}/${file}"
      log_success "${file} removed from TPU VM"
    # Then check in the utils directory
    elif ssh_with_timeout "test -f ${TARGET_DIR}/utils/${file} && echo 'exists'" | grep -q "exists"; then
      log "Removing ${file} from utils directory..."
      ssh_with_timeout "rm -f ${TARGET_DIR}/utils/${file}"
      log_success "${file} removed from utils directory"
    else
      log_warning "${file} not found on TPU VM - already removed or never mounted"
    fi
  done
fi

# Prune Docker volumes if we removed anything
if [[ "$REMOVE_UTILS" == "true" || ${#FILES_TO_REMOVE[@]} -gt 0 || "$REMOVE_ALL" == "true" ]]; then
  log "Pruning unused Docker volumes..."
  ssh_with_timeout "docker volume prune -f" 15
  log_success "Docker volume pruning complete"
fi

log_success "Cleanup process completed successfully"
exit 0