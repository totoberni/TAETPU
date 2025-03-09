#!/bin/bash

# --- DETERMINE SCRIPT AND PROJECT DIRECTORIES ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_DIR/dev/src"

# --- IMPORT COMMON FUNCTIONS ---
source "$PROJECT_DIR/src/utils/common.sh"

# --- USAGE INFORMATION ---
show_usage() {
  echo "Usage: $0 [--all] [--dir directory] [file1.py file2.py ...]"
  echo ""
  echo "Mount source code to the TPU VM container."
  echo ""
  echo "Options:"
  echo "  --all                Mount all contents of dev/src directory"
  echo "  --dir directory      Mount a specific directory from dev/src"
  echo "  file1.py file2.py    Specific files to mount (from dev/src)"
  echo "  -h, --help           Show this help message"
  echo ""
  exit 1
}

# --- PARSE COMMAND-LINE ARGUMENTS ---
MOUNT_ALL=false
SPECIFIC_FILES=()
DIRECTORIES=()

if [ $# -eq 0 ]; then
  # Default behavior: copy Python files
  log "No files specified, mounting all Python files..."
  MOUNT_ALL=false
else
  while [[ $# -gt 0 ]]; do
    case $1 in
      --all)
        MOUNT_ALL=true
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
      -h|--help)
        show_usage
        ;;
      *)
        # Accept any file
        SPECIFIC_FILES+=("$1")
        shift
        ;;
    esac
  done
fi

# --- LOAD ENVIRONMENT VARIABLES ---
log "Loading environment variables..."
source "$PROJECT_DIR/source/.env"
log "Environment variables loaded successfully"

# --- VALIDATE REQUIRED ENVIRONMENT VARIABLES ---
check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_NAME" || exit 1

# Define mount paths (same as in run.sh)
MOUNT_PATH="/tmp/app/mount"
CONTAINER_MOUNT_PATH="/app/mount"

log "Mounting source code to TPU VM"
log "- TPU Name: $TPU_NAME"
log "- Mount all files: $MOUNT_ALL"
if [ ${#SPECIFIC_FILES[@]} -gt 0 ]; then
  log "- Files to mount: ${SPECIFIC_FILES[*]}"
fi
if [ ${#DIRECTORIES[@]} -gt 0 ]; then
  log "- Directories to mount: ${DIRECTORIES[*]}"
fi

# --- CREATE TARGET DIRECTORY ---
log "Creating target directory on TPU VM..."
vmssh "mkdir -p $MOUNT_PATH"

# Create a temporary directory for transferring files
TEMP_DIR=$(mktemp -d)
trap 'rm -rf $TEMP_DIR' EXIT

# --- PREPARE FILES TO TRANSFER ---
if [[ "$MOUNT_ALL" == "true" ]]; then
  # Copy all files from src directory
  log "Copying all files from $SRC_DIR..."
  cp -r "$SRC_DIR/"* "$TEMP_DIR/" 2>/dev/null || true
else
  # Copy specific files
  if [ ${#SPECIFIC_FILES[@]} -gt 0 ]; then
    log "Copying specified files..."
    
    for file in "${SPECIFIC_FILES[@]}"; do
      # Direct access to files in src directory
      if [ -f "$SRC_DIR/$file" ]; then
        cp "$SRC_DIR/$file" "$TEMP_DIR/"
        log "- Copied $file"
      else
        log_warning "- File $file not found in $SRC_DIR"
      fi
    done
  fi
  
  # Copy specific directories
  if [ ${#DIRECTORIES[@]} -gt 0 ]; then
    log "Copying specified directories..."
    
    for dir in "${DIRECTORIES[@]}"; do
      if [ -d "$SRC_DIR/$dir" ]; then
        mkdir -p "$TEMP_DIR/$dir"
        cp -r "$SRC_DIR/$dir/"* "$TEMP_DIR/$dir/" 2>/dev/null || true
        log "- Copied directory $dir"
      else
        log_warning "- Directory $dir not found in $SRC_DIR"
      fi
    done
  fi
  
  # Default behavior if no files or directories specified
  if [ ${#SPECIFIC_FILES[@]} -eq 0 ] && [ ${#DIRECTORIES[@]} -eq 0 ]; then
    log "Copying Python files from $SRC_DIR..."
    find "$SRC_DIR" -name "*.py" -exec cp {} "$TEMP_DIR/" \;
  fi
fi

# --- TRANSFER FILES TO TPU VM ---
if [ -z "$(ls -A "$TEMP_DIR")" ]; then
  log_warning "No files to transfer!"
else
  log "Transferring files to TPU VM..."
  # Clear the target directory first to avoid stale files
  vmssh "rm -rf $MOUNT_PATH/*"
  
  # Transfer files
  gcloud compute tpus tpu-vm scp --recurse "$TEMP_DIR/"* "$TPU_NAME":"$MOUNT_PATH/" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all
fi

# --- VERIFY MOUNTED FILES ---
log "Verifying mounted files on TPU VM..."
vmssh "ls -la $MOUNT_PATH/"

log_success "Mount completed successfully"
log "Files are available in the Docker container at $CONTAINER_MOUNT_PATH"
log "To run Python files, use: ./dev/mgt/run.sh [filename.py]" 