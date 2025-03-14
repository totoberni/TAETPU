#!/bin/bash

# --- Basic setup ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_DIR/dev/src"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common.sh"

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
        echo "Mount source code to TPU VM."
        exit 0
        ;;
      *) SPECIFIC_FILES+=("$1"); shift ;;
    esac
  done
fi

# --- Load environment variables ---
source "$PROJECT_DIR/source/.env"
check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_NAME" || exit 1

# --- Create remote directory ---
log_section "Preparing Mount Environment"
log "Ensuring mount directory exists on TPU VM"
vmssh "mkdir -p /tmp/app/mount"

# --- Mount operations ---
if [[ "$MOUNT_ALL" == "true" ]]; then
  log_section "All Files Mount"
  log "Mounting all files from $SRC_DIR"
  
  # Clear existing files and copy all source files
  vmssh "rm -rf /tmp/app/mount/*"
  gcloud compute tpus tpu-vm scp --recurse "$SRC_DIR/"* "$TPU_NAME":"/tmp/app/mount/" \
      --zone="$TPU_ZONE" \
      --project="$PROJECT_ID" \
      --worker=all
      
  log_success "All files mounted to /tmp/app/mount"
else
  # Mount specific files and directories
  if [ ${#SPECIFIC_FILES[@]} -gt 0 ]; then
    log_section "Specific Files Mount"
    log "Mounting specific files to TPU VM"
    
    for file in "${SPECIFIC_FILES[@]}"; do
      src_file="$SRC_DIR/$file"
      if [ -f "$src_file" ]; then
        # Create parent directory if needed
        parent_dir=$(dirname "$file")
        if [ "$parent_dir" != "." ]; then
          vmssh "mkdir -p /tmp/app/mount/$parent_dir"
        fi
        
        # Copy file
        gcloud compute tpus tpu-vm scp "$src_file" "$TPU_NAME":"/tmp/app/mount/$file" \
            --zone="$TPU_ZONE" \
            --project="$PROJECT_ID" \
            --worker=all
            
        log "Mounted $file"
      else
        log_warning "File $file not found in $SRC_DIR"
      fi
    done
  fi
  
  # Mount directories
  if [ ${#DIRECTORIES[@]} -gt 0 ]; then
    log_section "Directory Mount"
    log "Mounting directories to TPU VM"
    
    for dir in "${DIRECTORIES[@]}"; do
      src_dir="$SRC_DIR/$dir"
      if [ -d "$src_dir" ]; then
        vmssh "mkdir -p /tmp/app/mount/$dir"
        
        gcloud compute tpus tpu-vm scp --recurse "$src_dir/"* "$TPU_NAME":"/tmp/app/mount/$dir/" \
            --zone="$TPU_ZONE" \
            --project="$PROJECT_ID" \
            --worker=all
            
        log_success "Mounted directory $dir"
      else
        log_warning "Directory $dir not found in $SRC_DIR"
      fi
    done
  fi
  
  # If nothing specified, mount all Python files
  if [ ${#SPECIFIC_FILES[@]} -eq 0 ] && [ ${#DIRECTORIES[@]} -eq 0 ]; then
    log_section "Default Python Files Mount"
    log "No specific files/directories specified, mounting all Python files"
    
    find "$SRC_DIR" -name "*.py" | while read -r py_file; do
      rel_path=${py_file#"$SRC_DIR/"}
      parent_dir=$(dirname "$rel_path")
      
      vmssh "mkdir -p /tmp/app/mount/$parent_dir"
      
      gcloud compute tpus tpu-vm scp "$py_file" "$TPU_NAME":"/tmp/app/mount/$rel_path" \
          --zone="$TPU_ZONE" \
          --project="$PROJECT_ID" \
          --worker=all
    done
    
    log_success "All Python files mounted"
  fi
fi

# --- Update file listing ---
log_section "Finalizing Mount"
vmssh "find /tmp/app/mount -type f > /tmp/app/mount_files.txt" || true

log_success "Files mounted successfully at /app/mount in the container"
exit 0