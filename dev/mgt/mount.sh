#!/bin/bash

# --- DETERMINE SCRIPT AND PROJECT DIRECTORIES ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_DIR/dev/src"

# --- IMPORT COMMON FUNCTIONS ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

show_usage() {
  echo "Usage: $0 [-a|--all] [file1.py file2.py ...] [--utils]"
  echo ""
  echo "Mount specified files from dev/src to the TPU VM container."
  echo ""
  echo "Options:"
  echo "  -a, --all    Mount all files from dev/src directory, including utils"
  echo "  --utils      Mount the utils directory (recursively)"
  echo "  -h, --help   Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 example.py               # Mount only example.py"
  echo "  $0 model.py data_utils.py   # Mount multiple specific files"
  echo "  $0 --all                    # Mount all files in dev/src"
  echo "  $0 --utils                  # Mount only the utils directory"
  echo "  $0 example.py --utils       # Mount example.py and the utils directory"
  echo ""
  echo "Note: This script can be run from any directory in the codebase"
  exit 1
}

# Function to create a temporary file with mount information
create_mount_info() {
  local mount_info_file="$PROJECT_DIR/source/.mount_info.tmp"
  
  # Create or clear the file
  > "$mount_info_file"
  
  # Add timestamp
  echo "TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')" >> "$mount_info_file"
  
  # Add mounted files list (space-separated)
  echo "MOUNTED_FILES=\"${FILES_TO_MOUNT[*]}\"" >> "$mount_info_file"
  
  # Add utils directory mount status
  echo "UTILS_MOUNTED=$MOUNT_UTILS" >> "$mount_info_file"
  
  # Add target directory on TPU VM
  echo "TPU_TARGET_DIR=/tmp/dev/src" >> "$mount_info_file"
  
  log "Mount information saved to temporary file"
}

# --- MAIN SCRIPT ---
# Parse command line arguments
MOUNT_ALL=false
MOUNT_UTILS=false
FILES_TO_MOUNT=()

if [ $# -eq 0 ]; then
  show_usage
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    -a|--all)
      MOUNT_ALL=true
      shift # shift past the argument
      ;;
    --utils)
      MOUNT_UTILS=true
      shift # shift past the argument
      ;;
    -h|--help)
      show_usage
      ;;
    *)
      # Assume this is a file to mount
      FILES_TO_MOUNT+=("$1")
      shift # shift past the argument
      ;;
  esac
done

log 'Starting TPU development environment mount process...'

log 'Loading environment variables...'
source "$PROJECT_DIR/source/.env"
log 'Environment variables loaded successfully'

# Validate required environment variables
check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_NAME"

log "Configuration:"
log "- Project ID: $PROJECT_ID"
log "- TPU Zone: $TPU_ZONE"
log "- TPU Name: $TPU_NAME"

# Set up authentication if provided
setup_auth

# Determine which files to mount
if [[ "$MOUNT_ALL" == "true" ]]; then
  log "Preparing to mount all files from dev/src directory"
  # Get all Python files in the src directory that actually exist (excluding utils dir)
  FILES_TO_MOUNT=()
  while IFS= read -r file; do
    if [[ -f "$file" ]]; then
      FILES_TO_MOUNT+=("$(basename "$file")")
    fi
  done < <(find "$SRC_DIR" -maxdepth 1 -type f -name "*.py")
  
  # Check if we found any files
  if [[ ${#FILES_TO_MOUNT[@]} -eq 0 ]]; then
    log_warning "No Python files found in $SRC_DIR root directory"
  else
    log "Found ${#FILES_TO_MOUNT[@]} Python files to mount in root directory"
  fi
  
  # Always mount utils directory with --all flag
  MOUNT_UTILS=true
else
  # Only mount specified files that exist
  log "Preparing to mount specified files: ${FILES_TO_MOUNT[*]}"
  VALID_FILES=()
  for file in "${FILES_TO_MOUNT[@]}"; do
    if [[ -f "$SRC_DIR/$file" ]]; then
      VALID_FILES+=("$file")
    else
      log_warning "File '$file' not found in $SRC_DIR - skipping"
    fi
  done
  FILES_TO_MOUNT=("${VALID_FILES[@]}")
  
  if [[ ${#FILES_TO_MOUNT[@]} -eq 0 && "$MOUNT_UTILS" == "false" ]]; then
    log_error "No valid files to mount"
    exit 1
  fi
fi

# Create directory on TPU VM for mounting
log "Setting up TPU VM for file mounting..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all \
    --command="mkdir -p /tmp/dev/src/utils"

# Copy each file to the TPU VM
if [[ ${#FILES_TO_MOUNT[@]} -gt 0 ]]; then
  log "Copying files to TPU VM..."
  for file in "${FILES_TO_MOUNT[@]}"; do
    log "- Mounting $file"
    if gcloud compute tpus tpu-vm scp "$SRC_DIR/$file" "$TPU_NAME":/tmp/dev/src/ \
        --zone="$TPU_ZONE" \
        --project="$PROJECT_ID" \
        --worker=all; then
      log_success "Successfully mounted $file"
    else
      log_warning "Failed to mount $file - continuing with next file"
    fi
  done
else
  log "No root-level files to copy"
fi

# Copy utils directory if requested
if [[ "$MOUNT_UTILS" == "true" ]]; then
  if [[ -d "$SRC_DIR/utils" ]]; then
    log "- Mounting utils directory"
    
    # Check if there are any files in the utils directory
    UTILS_FILES=$(find "$SRC_DIR/utils" -type f -name "*.py" | wc -l)
    
    if [[ $UTILS_FILES -eq 0 ]]; then
      log_warning "Utils directory exists but contains no Python files - creating empty directory"
      # Just ensure the directory exists on TPU
      gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
          --zone="$TPU_ZONE" \
          --project="$PROJECT_ID" \
          --worker=all \
          --command="mkdir -p /tmp/dev/src/utils"
    else
      log "Found $UTILS_FILES Python files in utils directory"
      
      # Create a temporary directory for the utils files
      TEMP_DIR=$(mktemp -d)
      
      # Copy the utils directory to the temporary location
      cp -r "$SRC_DIR/utils/"* "$TEMP_DIR/" 2>/dev/null || true
      
      # Use recursive copy for the utils directory
      if gcloud compute tpus tpu-vm scp --recurse "$TEMP_DIR/"* "$TPU_NAME":/tmp/dev/src/utils/ \
          --zone="$TPU_ZONE" \
          --project="$PROJECT_ID" \
          --worker=all; then
        log_success "Successfully mounted utils directory"
      else
        log_warning "Failed to mount utils directory"
      fi
      
      # Clean up temporary directory
      rm -rf "$TEMP_DIR"
    fi
  else
    log_warning "Utils directory doesn't exist, creating empty directory on TPU"
    gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
        --zone="$TPU_ZONE" \
        --project="$PROJECT_ID" \
        --worker=all \
        --command="mkdir -p /tmp/dev/src/utils"
  fi
fi

# Create info file with mount details
create_mount_info

# List mounted files for verification
log "Verifying mounted files on TPU VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all \
    --command="ls -la /tmp/dev/src/" || log_warning "Failed to list files, but mount process may have succeeded"

# If utils was mounted, also check the utils directory
if [[ "$MOUNT_UTILS" == "true" ]]; then
  log "Verifying utils directory:"
  gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
      --zone="$TPU_ZONE" \
      --project="$PROJECT_ID" \
      --worker=all \
      --command="ls -la /tmp/dev/src/utils/" || log_warning "Failed to list utils directory, but mount process may have succeeded"
fi

log_success "Mount process completed successfully."
log "Files are available in the Docker container when mounted at /app/dev/src"
log "To run these files, use: ./dev/mgt/run.sh [filename.py]" 