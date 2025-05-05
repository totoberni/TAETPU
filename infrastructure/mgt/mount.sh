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
    
    # Copy the entire src directory to temp
    if [ -d "./src" ]; then
        cp -r ./src/* "$LOCAL_TEMP_DIR/"
    else
        log_error "Local ./src directory not found"
        exit 1
    fi
    
    # Set target directory in container
    TARGET_DIR="${CONTAINER_MOUNT_DIR:-/app/mount}/src"
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
    TARGET_DIR="${CONTAINER_MOUNT_DIR:-/app/mount}/src"
    if [[ "$TARGET_PATH" == *"/"* ]]; then
        # Extract directory path from TARGET_PATH
        DIR_PART=$(dirname "$TARGET_PATH")
        TARGET_DIR="${TARGET_DIR}/${DIR_PART}"
    fi
fi

# Set default for HOST_MOUNT_DIR
HOST_MOUNT_DIR="${HOST_MOUNT_DIR:-mount}"

# First create a single small test file to upload
echo "test" > "$LOCAL_TEMP_DIR/test.txt"

# Create the remote directory and get absolute path (avoid ~ expansion issues)
log "Setting up remote directory on TPU VM"
gcloud compute tpus tpu-vm ssh ${TPU_NAME} \
    --zone="${TPU_ZONE}" \
    --project="${PROJECT_ID}" \
    --command="mkdir -p ${HOST_MOUNT_DIR} && echo 'Remote directory created'"

# Upload files one by one to avoid wildcard issues with Windows
log "Uploading to TPU VM (project: ${PROJECT_ID}, zone: ${TPU_ZONE}, TPU: ${TPU_NAME})"

# First, try to upload the test file to validate connectivity
gcloud compute tpus tpu-vm scp \
    --zone="${TPU_ZONE}" \
    --project="${PROJECT_ID}" \
    "${LOCAL_TEMP_DIR}/test.txt" \
    "${TPU_NAME}:${HOST_MOUNT_DIR}/"

log "Test file uploaded successfully, proceeding with full upload..."

# Then upload the actual content (requires temp dir with content)
if [ -n "$(ls -A ${LOCAL_TEMP_DIR})" ]; then
    # Create a tar file of the local temp directory
    TAR_FILE="${LOCAL_TEMP_DIR}/files.tar"
    tar -cf "${TAR_FILE}" -C "${LOCAL_TEMP_DIR}" .
    
    # Transfer the tar file to TPU VM
    gcloud compute tpus tpu-vm scp \
        --zone="${TPU_ZONE}" \
        --project="${PROJECT_ID}" \
        "${TAR_FILE}" \
        "${TPU_NAME}:${HOST_MOUNT_DIR}/"
    
    # Extract the tar file on the TPU VM
    gcloud compute tpus tpu-vm ssh ${TPU_NAME} \
        --zone="${TPU_ZONE}" \
        --project="${PROJECT_ID}" \
        --command="cd ${HOST_MOUNT_DIR} && tar -xf files.tar && rm files.tar"
else
    log_warning "No files found to upload"
fi

# Copy from TPU VM file system to Docker container
log "Copying into Docker container (${CONTAINER_NAME})"
gcloud compute tpus tpu-vm ssh ${TPU_NAME} \
    --zone="${TPU_ZONE}" \
    --project="${PROJECT_ID}" \
    --command="
        # Create target directory structure
        docker exec ${CONTAINER_NAME} mkdir -p $TARGET_DIR
        
        # Copy files from VM to container
        docker cp ${HOST_MOUNT_DIR}/. ${CONTAINER_NAME}:$TARGET_DIR/
        
        # Set proper permissions
        docker exec ${CONTAINER_NAME} chmod -R 777 $TARGET_DIR
    "

if [ "$IS_ALL" = true ]; then
    log_success "Successfully mounted entire ./src directory to container"
else
    log_success "Successfully mounted $([ "$IS_DIR" = true ] && echo "directory" || echo "file"): $TARGET_PATH"
fi
exit 0