#!/bin/bash

# --- Basic setup ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SRC_DIR="$PROJECT_DIR/tools/docker_ops/src"

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
        echo "Mount source code to TPU VM."
        exit 0
        ;;
      *) SPECIFIC_FILES+=("$1"); shift ;;
    esac
  done
fi

# --- Load environment variables ---
source "$PROJECT_DIR/config/.env"
check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_NAME" || exit 1

# --- Check and prepare directories ---
log_section "Preparing Mount Environment"
log "Checking mount directory structure on TPU VM"
# Check if mount directories exist, create only if needed
vmssh "if [ ! -d /app/mount/src ] || [ ! -d /app/mount/data ] || [ ! -d /app/mount/models ] || [ ! -d /app/mount/logs ]; then 
  sudo mkdir -p /app/mount/src /app/mount/data /app/mount/models /app/mount/logs
  sudo chmod 777 -R /app/mount
fi"
# Create temporary directory for file transfers
vmssh "mkdir -p /tmp/app/mount"

# --- Mount operations ---
if [[ "$MOUNT_ALL" == "true" ]]; then
  log_section "All Files Mount"
  log "Mounting all files from $SRC_DIR to /app/mount/src"
  
  # Clear existing files
  vmssh "sudo rm -rf /app/mount/src/*"
  vmssh "rm -rf /tmp/app/mount/*"
  
  # Copy all source files to temp directory first
  gcloud compute tpus tpu-vm scp --recurse "$SRC_DIR/"* "$TPU_NAME":"/tmp/app/mount/" \
      --zone="$TPU_ZONE" \
      --project="$PROJECT_ID" \
      --worker=all
  
  # Move files from temp to final destination
  vmssh "sudo cp -r /tmp/app/mount/* /app/mount/src/ && rm -rf /tmp/app/mount/*"
      
  log_success "All files mounted to /app/mount/src"
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
        
        # Copy file to temp directory
        gcloud compute tpus tpu-vm scp "$src_file" "$TPU_NAME":"/tmp/app/mount/$file" \
            --zone="$TPU_ZONE" \
            --project="$PROJECT_ID" \
            --worker=all
        
        # Create destination directory and move file
        vmssh "sudo mkdir -p /app/mount/src/$parent_dir && sudo cp /tmp/app/mount/$file /app/mount/src/$file"
            
        log "Mounted $file to /app/mount/src/$file"
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
        # Create temp directory
        vmssh "mkdir -p /tmp/app/mount/$dir"
        
        # Copy directory contents to temp
        gcloud compute tpus tpu-vm scp --recurse "$src_dir/"* "$TPU_NAME":"/tmp/app/mount/$dir/" \
            --zone="$TPU_ZONE" \
            --project="$PROJECT_ID" \
            --worker=all
        
        # Create destination directory and move files
        vmssh "sudo mkdir -p /app/mount/src/$dir && sudo cp -r /tmp/app/mount/$dir/* /app/mount/src/$dir/"
            
        log_success "Mounted directory $dir to /app/mount/src/$dir"
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
      
      # Create temp and destination directories
      vmssh "mkdir -p /tmp/app/mount/$parent_dir"
      vmssh "sudo mkdir -p /app/mount/src/$parent_dir"
      
      # Copy to temp and move to destination
      gcloud compute tpus tpu-vm scp "$py_file" "$TPU_NAME":"/tmp/app/mount/$rel_path" \
          --zone="$TPU_ZONE" \
          --project="$PROJECT_ID" \
          --worker=all
      
      vmssh "sudo cp /tmp/app/mount/$rel_path /app/mount/src/$rel_path"
    done
    
    log_success "All Python files mounted to /app/mount/src"
  fi
fi

# Clean up temp directory
vmssh "sudo rm -rf /tmp/app/mount/*"

# Ensure correct permissions
vmssh "sudo chmod -R 777 /app/mount"

log_success "Files mounted successfully at /app/mount in the container"
exit 0