#!/bin/bash

# --- DETERMINE SCRIPT AND PROJECT DIRECTORIES ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_DIR/dev/src"

# --- DEFINE PATH CONSTANTS - Use these consistently across all scripts ---
TPU_HOST_PATH="/tmp/dev/src"
DOCKER_CONTAINER_PATH="/app/dev/src"

# --- IMPORT COMMON FUNCTIONS ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

# --- HELPER FUNCTIONS ---
show_usage() {
  echo "Usage: $0 [-a|--all] [file1.py file2.sh ...] [--utils]"
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
  echo "  $0 run_example.sh           # Mount a shell script"
  echo "  $0 model.py data_utils.py   # Mount multiple specific files"
  echo "  $0 --all                    # Mount all files in dev/src"
  echo "  $0 --utils                  # Mount only the utils directory"
  echo "  $0 example.py --utils       # Mount example.py and the utils directory"
  echo ""
  echo "Note: This script can be run from any directory in the codebase"
  exit 1
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
log "- TPU Host Path: $TPU_HOST_PATH"
log "- Docker Container Path: $DOCKER_CONTAINER_PATH"

# Set up authentication if provided
setup_auth

# Determine which files to mount
if [[ "$MOUNT_ALL" == "true" ]]; then
  log "Preparing to mount all files from dev/src directory"
  # Get all files in the src directory (excluding utils dir)
  FILES_TO_MOUNT=()
  while IFS= read -r file; do
    if [[ -f "$file" ]]; then
      # Get just the filename from the path
      filename=$(basename "$file")
      FILES_TO_MOUNT+=("$filename")
    fi
  done < <(find "$SRC_DIR" -maxdepth 1 -type f)
  
  # Check if we found any files
  if [[ ${#FILES_TO_MOUNT[@]} -eq 0 ]]; then
    log_warning "No files found in $SRC_DIR root directory"
  else
    log "Found ${#FILES_TO_MOUNT[@]} files to mount in root directory"
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
    --command="mkdir -p ${TPU_HOST_PATH}/utils"

# Copy each file to the TPU VM
if [[ ${#FILES_TO_MOUNT[@]} -gt 0 ]]; then
  log "Copying files to TPU VM..."
  for file in "${FILES_TO_MOUNT[@]}"; do
    log "- Mounting $file"
    if gcloud compute tpus tpu-vm scp "$SRC_DIR/$file" "$TPU_NAME":${TPU_HOST_PATH}/ \
        --zone="$TPU_ZONE" \
        --project="$PROJECT_ID" \
        --worker=all; then
      
      # Make shell scripts executable on the TPU VM
      if [[ "$file" == *.sh ]]; then
        log "Making $file executable on TPU VM..."
        gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
          --zone="$TPU_ZONE" \
          --project="$PROJECT_ID" \
          --worker=all \
          --command="chmod +x ${TPU_HOST_PATH}/${file}"
        log_success "Successfully made $file executable"
      fi
      
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
  # Always try to mount common_logging.sh from src/utils first
  UTILS_SRC_DIR="$PROJECT_DIR/src/utils"
  if [[ -d "$UTILS_SRC_DIR" ]]; then
    log "- Mounting utils from $UTILS_SRC_DIR"
    
    # Create a temporary directory for the utils files
    TEMP_DIR=$(mktemp -d)
    
    # Copy common_logging.sh from src/utils
    if [[ -f "$UTILS_SRC_DIR/common_logging.sh" ]]; then
      log "Copying common_logging.sh from src/utils"
      cp "$UTILS_SRC_DIR/common_logging.sh" "$TEMP_DIR/"
    else
      log_warning "common_logging.sh not found in src/utils"
    fi
    
    # Also copy any additional utils from dev/src/utils if they exist
    if [[ -d "$SRC_DIR/utils" ]]; then
      log "Also copying utilities from dev/src/utils"
      cp -r "$SRC_DIR/utils/"* "$TEMP_DIR/" 2>/dev/null || true
    fi
    
    # Use recursive copy for the utils directory
    if gcloud compute tpus tpu-vm scp --recurse "$TEMP_DIR/"* "$TPU_NAME":${TPU_HOST_PATH}/utils/ \
        --zone="$TPU_ZONE" \
        --project="$PROJECT_ID" \
        --worker=all; then
      
      # Make all shell scripts in utils executable
      for script in $(find "$TEMP_DIR" -name "*.sh" 2>/dev/null); do
        script_name=$(basename "$script")
        log "Making $script_name executable..."
        gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
          --zone="$TPU_ZONE" \
          --project="$PROJECT_ID" \
          --worker=all \
          --command="chmod +x ${TPU_HOST_PATH}/utils/${script_name}"
      done
      
      log_success "Successfully mounted utils directory"
    else
      log_warning "Failed to mount utils directory"
    fi
    
    # Clean up temporary directory
    rm -rf "$TEMP_DIR"
  else
    log_warning "Neither src/utils nor dev/src/utils directories exist"
    # Create an empty utils directory on TPU
    gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
        --zone="$TPU_ZONE" \
        --project="$PROJECT_ID" \
        --worker=all \
        --command="mkdir -p ${TPU_HOST_PATH}/utils"
  fi
fi

# List mounted files for verification
log "Verifying mounted files on TPU VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all \
    --command="ls -la ${TPU_HOST_PATH}/" || log_warning "Failed to list files, but mount process may have succeeded"

# If utils was mounted, also check the utils directory
if [[ "$MOUNT_UTILS" == "true" ]]; then
  log "Verifying utils directory:"
  gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
      --zone="$TPU_ZONE" \
      --project="$PROJECT_ID" \
      --worker=all \
      --command="ls -la ${TPU_HOST_PATH}/utils/" || log_warning "Failed to list utils directory, but mount process may have succeeded"
fi

log_success "Mount process completed successfully."
log "Files are mounted on TPU VM at: ${TPU_HOST_PATH}"
log "In Docker container, these will be available at: ${DOCKER_CONTAINER_PATH}"
log "To run Python files, use: ./dev/mgt/run.sh [filename.py]"
log "To run shell scripts, use: ./dev/mgt/run.sh [filename.sh]" 