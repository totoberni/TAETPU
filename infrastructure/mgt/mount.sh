#!/bin/bash
set -e

# Source environment variables
source $(dirname "$0")/../utils/common.sh

# Initialize
init_script 'Mount Files to Container'

# Check if a file path was provided
if [ $# -lt 1 ]; then
    log_error "Usage: $0 <file_path> [--dir]"
    log_error "  --dir: Optional flag to indicate copying a directory"
    exit 1
fi

FILE_PATH="$1"
IS_DIR=false

# Check for directory flag
if [[ "$*" == *"--dir"* ]]; then
    IS_DIR=true
fi

# Determine if we need to create target directories
TARGET_DIR="${CONTAINER_MOUNT_DIR}/src"
if [[ "$FILE_PATH" == *"/"* ]]; then
    # Extract directory path from FILE_PATH
    DIR_PART=$(dirname "$FILE_PATH")
    TARGET_DIR="${TARGET_DIR}/${DIR_PART}"
fi

# Create local temp directory
LOCAL_TEMP_DIR=$(mktemp -d)
trap "rm -rf $LOCAL_TEMP_DIR" EXIT

# Copy file or directory to temp directory
if [ "$IS_DIR" = true ]; then
    log "Copying directory: $FILE_PATH"
    mkdir -p "$LOCAL_TEMP_DIR/$(dirname "$FILE_PATH")"
    cp -r "$FILE_PATH" "$LOCAL_TEMP_DIR/$(dirname "$FILE_PATH")/"
else
    log "Copying file: $FILE_PATH"
    mkdir -p "$LOCAL_TEMP_DIR/$(dirname "$FILE_PATH")"
    cp "$FILE_PATH" "$LOCAL_TEMP_DIR/$(dirname "$FILE_PATH")/"
fi

# Upload to TPU VM
log "Uploading to TPU VM"
gcloud compute tpus tpu-vm scp \
    --recurse \
    "$LOCAL_TEMP_DIR/"* \
    "${TPU_NAME}:~/${HOST_MOUNT_DIR#./}/" \
    --zone=${TPU_ZONE} \
    --project=${PROJECT_ID}

# Copy from TPU VM file system to Docker container
log "Copying into Docker container"
gcloud compute tpus tpu-vm ssh ${TPU_NAME} \
    --zone=${TPU_ZONE} \
    --project=${PROJECT_ID} \
    --command="
        # Create target directory structure
        docker exec ${CONTAINER_NAME} mkdir -p $TARGET_DIR
        
        # Copy files from VM to container
        docker cp ~/${HOST_MOUNT_DIR#./}/. ${CONTAINER_NAME}:$TARGET_DIR/
        
        # Set proper permissions
        docker exec ${CONTAINER_NAME} chmod -R 777 $TARGET_DIR
    "

log_success "Successfully mounted $([ "$IS_DIR" = true ] && echo "directory" || echo "file"): $FILE_PATH"
exit 0