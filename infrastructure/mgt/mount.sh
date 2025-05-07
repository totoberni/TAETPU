#!/bin/bash
set -e

# Get the project directory (2 levels up from this script)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/../.." &> /dev/null && pwd )"
ENV_FILE="$PROJECT_DIR/config/.env"

# Source common utilities
source "$SCRIPT_DIR/../utils/common.sh"

# Initialize
init_script 'Mount Files to Container'

# Load environment variables from .env file
log "Loading environment variables from $ENV_FILE"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    log_error "Environment file not found: $ENV_FILE"
    exit 1
fi

# Check required environment variables
log "Checking required environment variables"
check_env_vars "PROJECT_ID" "TPU_NAME" "TPU_ZONE" "CONTAINER_NAME" || exit 1

# Process arguments
IS_ALL=false
TARGET_PATH=""

if [ $# -eq 0 ]; then
    log_error "Usage: $0 <file_path> [--dir] OR $0 --all"
    log_error "  --all: Mount the entire local ./src directory"
    log_error "  --dir: Optional flag to indicate copying a directory"
    exit 1
fi

# Check for --all flag
if [[ "$1" == "--all" ]]; then
    IS_ALL=true
else
    TARGET_PATH="$1"
    IS_DIR=false
    # Check for directory flag
    if [[ "$*" == *"--dir"* ]]; then
        IS_DIR=true
    fi
fi

# Create local temp directory
LOCAL_TEMP_DIR=$(mktemp -d)
trap "rm -rf $LOCAL_TEMP_DIR" EXIT

# Handle --all flag (upload entire src directory)
if [ "$IS_ALL" = true ]; then
    log "Mounting entire local ./src directory"
    
    # Copy the entire src directory structure to temp (not just contents)
    if [ -d "./src" ]; then
        # Create src directory in temp dir to preserve structure
        mkdir -p "$LOCAL_TEMP_DIR/src"
        
        # Copy contents preserving structure
        cp -r ./src/* "$LOCAL_TEMP_DIR/src/"
        
        log "Prepared local src directory structure for transfer"
    else
        log_error "Local ./src directory not found"
        exit 1
    fi
    
    # Set target directory in container
    TARGET_DIR="${CONTAINER_MOUNT_DIR:-/app/mount}"
else
    # Handle specific file or directory
    if [ "$IS_DIR" = true ]; then
        log "Copying directory: $TARGET_PATH"
        mkdir -p "$LOCAL_TEMP_DIR/$(dirname "$TARGET_PATH")"
        cp -r "$TARGET_PATH" "$LOCAL_TEMP_DIR/$(dirname "$TARGET_PATH")/"
    else
        log "Copying file: $TARGET_PATH"
        mkdir -p "$LOCAL_TEMP_DIR/$(dirname "$TARGET_PATH")"
        cp "$TARGET_PATH" "$LOCAL_TEMP_DIR/$(dirname "$TARGET_PATH")/"
    fi
    
    # Determine target directory in container
    TARGET_DIR="${CONTAINER_MOUNT_DIR:-/app/mount}"
    if [[ "$TARGET_PATH" == *"/"* ]]; then
        # Extract directory path from TARGET_PATH
        DIR_PART=$(dirname "$TARGET_PATH")
        TARGET_DIR="${TARGET_DIR}/${DIR_PART}"
    fi
fi

# Set default for HOST_MOUNT_DIR
HOST_MOUNT_DIR="${HOST_MOUNT_DIR:-mount}"

# Create the remote directory and get absolute path (avoid ~ expansion issues)
log "Setting up remote directory on TPU VM"
gcloud compute tpus tpu-vm ssh ${TPU_NAME} \
    --zone="${TPU_ZONE}" \
    --project="${PROJECT_ID}" \
    --command="mkdir -p ${HOST_MOUNT_DIR} && echo 'Remote directory created'"

# Upload files using recursive approach to maintain directory structure
log "Uploading to TPU VM (project: ${PROJECT_ID}, zone: ${TPU_ZONE}, TPU: ${TPU_NAME})"

if [ -n "$(ls -A ${LOCAL_TEMP_DIR})" ]; then
    # Directly transfer files with directory structure preserved
    gcloud compute tpus tpu-vm scp \
        --recurse \
        --zone="${TPU_ZONE}" \
        --project="${PROJECT_ID}" \
        "${LOCAL_TEMP_DIR}/"* \
        "${TPU_NAME}:${HOST_MOUNT_DIR}/"
    
    log_success "Files transferred to TPU VM with directory structure preserved"
else
    log_warning "No files found to upload"
fi

# Copy from TPU VM file system to Docker container
log "Copying into Docker container (${CONTAINER_NAME})"
gcloud compute tpus tpu-vm ssh ${TPU_NAME} \
    --zone="${TPU_ZONE}" \
    --project="${PROJECT_ID}" \
    --command="
        # Create target directory structure in container
        sudo docker exec ${CONTAINER_NAME} mkdir -p ${CONTAINER_MOUNT_DIR:-/app/mount}
        
        # Copy files from VM to container with proper path preservation
        if [ \"$IS_ALL\" = true ]; then
            # For --all, copy the src directory and its contents to maintain isometry
            sudo docker cp ${HOST_MOUNT_DIR}/src ${CONTAINER_NAME}:${CONTAINER_MOUNT_DIR:-/app/mount}/
        else
            # For specific files/dirs, respect the target directory structure
            sudo docker cp ${HOST_MOUNT_DIR}/. ${CONTAINER_NAME}:$TARGET_DIR/
        fi
        
        # Set proper permissions
        sudo docker exec ${CONTAINER_NAME} chmod -R 777 ${CONTAINER_MOUNT_DIR:-/app/mount}
    "

if [ "$IS_ALL" = true ]; then
    log_success "Successfully mounted entire ./src directory to container"
    vmssh "echo 'Container contents after mount:'; sudo docker exec ${CONTAINER_NAME} ls -la ${CONTAINER_MOUNT_DIR}"
else
    log_success "Successfully mounted $([ "$IS_DIR" = true ] && echo "directory" || echo "file"): $TARGET_PATH"
fi
exit 0