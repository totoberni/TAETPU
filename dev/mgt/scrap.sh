#!/bin/bash

# --- Basic setup ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common.sh"

# --- Parse arguments ---
REMOVE_ALL=false
FILES=()
DIRECTORIES=()
PRUNE_VOLUMES=false

if [ $# -eq 0 ]; then
  echo "Usage: $0 [--all] [--dir directory] [file1.py file2.py ...] [--prune]"
  echo "Remove files from TPU VM."
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) REMOVE_ALL=true; shift ;;
    --dir) DIRECTORIES+=("$2"); shift 2 ;;
    --prune) PRUNE_VOLUMES=true; shift ;;
    *.py|*.txt|*.yaml|*.json) FILES+=("$1"); shift ;;
    *) echo "Unknown argument: $1"; shift ;;
  esac
done

# --- Load environment variables ---
source "$PROJECT_DIR/source/.env"
check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_NAME" || exit 1

# --- Perform actions based on arguments ---
# For removing all files
if [ "$REMOVE_ALL" = true ]; then
  if confirm_delete "ALL files in the TPU VM mount directory"; then
    log "Removing all files from TPU VM"
    vmssh "rm -rf /tmp/app/mount/*"
    log_success "All files removed"
  else
    log "Operation cancelled by user"
    exit 0
  fi
fi

# For removing specific directories
if [ ${#DIRECTORIES[@]} -gt 0 ]; then
  log_section "Directory Operations"
  log "Directories selected for deletion:"
  for dir in "${DIRECTORIES[@]}"; do
    log "  - $dir"
  done
  
  if confirm_delete "these directories"; then
    for dir in "${DIRECTORIES[@]}"; do
      log "Processing directory: $dir"
      vmssh "rm -rf /tmp/app/mount/$dir"
      log_success "Directory processed: $dir"
    done
  else
    log "Directory deletion cancelled by user"
  fi
fi

# For removing specific files
if [ ${#FILES[@]} -gt 0 ]; then
  log_section "File Operations"
  log "Files selected for deletion:"
  for file in "${FILES[@]}"; do
    log "  - $file"
  done
  
  if confirm_delete "these files"; then
    for file in "${FILES[@]}"; do
      log "Processing file: $file"
      vmssh "rm -f /tmp/app/mount/$file"
      log_success "File processed: $file"
    done
  else
    log "File deletion cancelled by user"
  fi
fi

# --- Prune Docker volumes ---
if [ "$PRUNE_VOLUMES" = true ]; then
  log_section "Docker Volume Pruning"
  if confirm_action "Would you like to prune Docker volumes on the TPU VM?" "n"; then
    log "Pruning Docker volumes on TPU VM"
    vmssh "sudo docker volume prune --force"
    log_success "Docker volumes pruned"
  else
    log "Docker volume pruning skipped by user"
  fi
fi

# --- List remaining files ---
log_section "Remaining Files"
log "Listing remaining files in tmp/app/mount directory..."
vmssh "find /tmp/app/mount -type f | sort"

log_success "Cleanup complete"
exit 0