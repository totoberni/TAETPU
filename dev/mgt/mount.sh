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
  echo "Mount source code as Docker volumes."
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
  # Default behavior: Mount Python files
  log "No files specified, mounting all Python files..."
  MOUNT_ALL=true
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

# Define Docker image path
DOCKER_IMAGE="gcr.io/${PROJECT_ID}/tae-tpu:v1"

# Define mount paths
CONTAINER_MOUNT_PATH="/app/mount"

log "Setting up Docker volumes"
log "- TPU Name: $TPU_NAME"
log "- Mount all files: $MOUNT_ALL"
if [ ${#SPECIFIC_FILES[@]} -gt 0 ]; then
  log "- Files to mount: ${SPECIFIC_FILES[*]}"
fi
if [ ${#DIRECTORIES[@]} -gt 0 ]; then
  log "- Directories to mount: ${DIRECTORIES[*]}"
fi

# --- CREATE DOCKER VOLUMES ---
# Using an array for volume mounts to properly handle spaces
VOLUME_MOUNTS=()

# Function to create and configure a Docker volume for a file or directory
create_volume_mount() {
  local src="$1"
  local dst="$2"
  
  if [ ! -e "$src" ]; then
    log_warning "Source '$src' does not exist, skipping"
    return 1
  fi
  
  log "Creating volume mount for: $src -> $dst"
  # Add to array with proper quoting
  VOLUME_MOUNTS+=("-v" "$src:$dst")
}

# --- PREPARE VOLUME MOUNTS ---
if [[ "$MOUNT_ALL" == "true" ]]; then
  # Mount the entire src directory
  create_volume_mount "$SRC_DIR" "$CONTAINER_MOUNT_PATH"
else
  # Mount specific files
  if [ ${#SPECIFIC_FILES[@]} -gt 0 ]; then
    log "Setting up specific file mounts..."
    
    for file in "${SPECIFIC_FILES[@]}"; do
      # Check if file exists in src directory
      src_file="$SRC_DIR/$file"
      if [ -f "$src_file" ]; then
        # Mount individual file
        create_volume_mount "$src_file" "$CONTAINER_MOUNT_PATH/$file"
        log "- Mounted $file"
      else
        log_warning "- File $file not found in $SRC_DIR"
      fi
    done
  fi
  
  # Mount specific directories
  if [ ${#DIRECTORIES[@]} -gt 0 ]; then
    log "Setting up directory mounts..."
    for dir in "${DIRECTORIES[@]}"; do
      src_dir="$SRC_DIR/$dir"
      if [ -d "$src_dir" ]; then
        # Mount the directory
        create_volume_mount "$src_dir" "$CONTAINER_MOUNT_PATH/$dir"
        log "- Mounted directory $dir"
      else
        log_warning "- Directory $dir not found in $SRC_DIR"
      fi
    done
  fi
  
  # Default behavior if no files or directories specified
  if [ ${#SPECIFIC_FILES[@]} -eq 0 ] && [ ${#DIRECTORIES[@]} -eq 0 ] && [ "$MOUNT_ALL" != "true" ]; then
    log "No specific files or directories specified, mounting all Python files..."
    for py_file in $(find "$SRC_DIR" -name "*.py"); do
      rel_path=${py_file#"$SRC_DIR/"}
      create_volume_mount "$py_file" "$CONTAINER_MOUNT_PATH/$rel_path"
    done
  fi
fi

# --- CREATE AND RUN A VERIFICATION CONTAINER ---
log "Verifying Docker volume mounts..."

# Configure Docker on TPU VM
vmssh "gcloud auth configure-docker gcr.io --quiet"

# Pull Docker image if needed
vmssh "sudo docker pull $DOCKER_IMAGE || echo 'Using cached image'"

# Build a properly escaped Docker command for verification
# We need to be careful with escaping quotes for SSH command
VOLUME_MOUNT_STR=""
for ((i=0; i<${#VOLUME_MOUNTS[@]}; i+=2)); do
  # For each pair of options (-v and the actual mount)
  # Properly escape for SSH transmission
  VOLUME_MOUNT_STR+="${VOLUME_MOUNTS[i]} \"${VOLUME_MOUNTS[i+1]}\" "
done

# Command to verify the mounted volumes
VERIFICATION_CMD="sudo docker run --rm $VOLUME_MOUNT_STR $DOCKER_IMAGE ls -la $CONTAINER_MOUNT_PATH"

# Run the verification
vmssh "$VERIFICATION_CMD"

log_success "Docker volumes configured successfully"
log "Files are available in the Docker container at $CONTAINER_MOUNT_PATH"
log "To run Python files, use: ./dev/mgt/run.sh [filename.py]"

exit 0 