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

# --- Remove files ---
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

for dir in "${DIRECTORIES[@]}"; do
  if confirm_delete "directory: $dir"; then
    log "Removing directory: $dir"
    vmssh "rm -rf /tmp/app/mount/$dir"
    log_success "Directory $dir removed"
  else
    log "Skipping directory: $dir"
  fi
done

for file in "${FILES[@]}"; do
  if confirm_delete "file: $file"; then
    log "Removing file: $file"
    vmssh "rm -f /tmp/app/mount/$file"
    log_success "File $file removed"
  else
    log "Skipping file: $file"
  fi
done

# --- Prune Docker volumes ---
if [ "$PRUNE_VOLUMES" = true ]; then
  if confirm_action "Would you like to prune Docker volumes on the TPU VM?" "n"; then
    log "Pruning Docker volumes on TPU VM"
    vmssh "sudo docker volume prune --force"
    log_success "Docker volumes pruned"
  else
    log "Docker volume pruning skipped by user"
  fi
fi

# --- Update file listing ---
vmssh "find /tmp/app/mount -type f > /tmp/app/mount_files.txt" || true

log_success "Cleanup complete"
exit 0