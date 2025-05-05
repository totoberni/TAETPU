#!/bin/bash
set -e

# Get the project directory (2 levels up from this script)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/../.." &> /dev/null && pwd )"
ENV_FILE="$PROJECT_DIR/config/.env"

# Source common utilities
source "$SCRIPT_DIR/../utils/common.sh"

# Initialize
init_script 'Sync Files with Container'

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

# Set up Docker authentication - simple direct approach
log_section "Docker Authentication"
if [ -n "${TPU_NAME}" ] && [ "${TPU_NAME}" != "local" ]; then
    # On TPU VM
    vmssh "gcloud auth print-access-token | sudo docker login -u oauth2accesstoken --password-stdin https://eu.gcr.io" || \
    log_warning "Docker authentication failed, but continuing..."
else
    # Local operation
    gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin https://eu.gcr.io || \
    log_warning "Docker authentication failed, but continuing..."
fi

# Set container paths - use same variable pattern as other scripts
CONTAINER_MOUNT_DIR="${CONTAINER_MOUNT_DIR:-/app/mount}"
HOST_MOUNT_DIR="${HOST_MOUNT_DIR:-mount}"
LOCAL_SRC_DIR="./src"

# Process arguments
IS_ALL=false
TARGET_PATH=""
IS_DRY_RUN=false
IS_VERBOSE=false

# Process command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --all)
            IS_ALL=true
            shift
            ;;
        --dry-run)
            IS_DRY_RUN=true
            shift
            ;;
        --verbose)
            IS_VERBOSE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--all] [--dry-run] [--verbose] [path/to/file_or_dir]"
            echo "  --all: Sync all files in the src directory"
            echo "  --dry-run: Show what would be updated without making changes"
            echo "  --verbose: Show detailed information about file comparison"
            echo "  path/to/file_or_dir: Specific file or directory to sync"
            exit 0
            ;;
        *)
            TARGET_PATH="$1"
            shift
            ;;
    esac
done

# Check if TPU VM is accessible
log "Checking TPU VM connection (project: ${PROJECT_ID}, zone: ${TPU_ZONE}, TPU: ${TPU_NAME})..."
vmssh "echo 'TPU VM connection successful'" || { log_error "Failed to connect to TPU VM. Check your configuration."; exit 1; }

# Check if Docker container is running
log "Checking Docker container status (${CONTAINER_NAME})..."
vmssh "sudo docker ps | grep -q ${CONTAINER_NAME}" || { log_error "Container ${CONTAINER_NAME} is not running on TPU VM."; exit 1; }

# Create temporary directories
LOCAL_TEMP_DIR=$(mktemp -d)
MANIFEST_DIR=$(mktemp -d)
trap "rm -rf $LOCAL_TEMP_DIR $MANIFEST_DIR" EXIT

# Generate local file manifest
log "Generating local file manifest..."
if [ "$IS_ALL" = true ]; then
    # List all files in src directory
    if [ -d "$LOCAL_SRC_DIR" ]; then
        find "$LOCAL_SRC_DIR" -type f -not -path "*/\.*" | sort > "$MANIFEST_DIR/local_files.txt"
    else
        log_error "Local ./src directory not found"
        exit 1
    fi
else
    # Handle specific file or directory
    if [ -z "$TARGET_PATH" ]; then
        log_error "No target path specified. Use --all or provide a specific path."
        exit 1
    fi
    
    if [ -d "$TARGET_PATH" ]; then
        # It's a directory
        find "$TARGET_PATH" -type f -not -path "*/\.*" | sort > "$MANIFEST_DIR/local_files.txt"
    elif [ -f "$TARGET_PATH" ]; then
        # It's a file
        echo "$TARGET_PATH" > "$MANIFEST_DIR/local_files.txt"
    else
        log_error "Target path does not exist: $TARGET_PATH"
        exit 1
    fi
fi

# Get file count
FILE_COUNT=$(wc -l < "$MANIFEST_DIR/local_files.txt")
log "Found $FILE_COUNT local files to check"

# Generate remote file manifest
log "Retrieving container file manifest..."
vmssh "
    sudo docker exec ${CONTAINER_NAME} find ${CONTAINER_MOUNT_DIR}/src -type f 2>/dev/null | sort > /tmp/container_files.txt || echo 'No files found in container src directory'
" || { log_warning "Failed to get container file list"; exit 1; }

# Copy the container file manifest to local machine
gcloud compute tpus tpu-vm scp \
    --zone="${TPU_ZONE}" \
    --project="${PROJECT_ID}" \
    "${TPU_NAME}:/tmp/container_files.txt" \
    "$MANIFEST_DIR/container_files.txt" 2>/dev/null || \
    echo "" > "$MANIFEST_DIR/container_files.txt"

# Compare file timestamps to determine what needs to be synced
log "Comparing local and container files..."

# Create lists for files to update and files to delete
mkdir -p "$LOCAL_TEMP_DIR/update"
mkdir -p "$LOCAL_TEMP_DIR/delete"

# Files to delete (files in container but not in local)
if [ "$IS_ALL" = true ]; then
    # Process container files to find ones that should be deleted
    log "Checking for files to delete..."
    
    # Create a list of normalized local paths for comparison
    cat "$MANIFEST_DIR/local_files.txt" | sed "s|^./src/||g" | sort > "$MANIFEST_DIR/local_normalized.txt"
    
    # Create a list of normalized container paths for comparison
    cat "$MANIFEST_DIR/container_files.txt" | sed "s|^${CONTAINER_MOUNT_DIR}/src/||g" | sort > "$MANIFEST_DIR/container_normalized.txt"
    
    # Find files to delete (in container but not local)
    comm -23 "$MANIFEST_DIR/container_normalized.txt" "$MANIFEST_DIR/local_normalized.txt" > "$MANIFEST_DIR/files_to_delete.txt"
    
    DELETE_COUNT=$(wc -l < "$MANIFEST_DIR/files_to_delete.txt")
    if [ "$DELETE_COUNT" -gt 0 ]; then
        log "Found $DELETE_COUNT files to delete"
        
        # If in dry run mode, just show what would be deleted
        if [ "$IS_DRY_RUN" = true ]; then
            log "DRY RUN - The following files would be deleted:"
            cat "$MANIFEST_DIR/files_to_delete.txt"
        else
            # Create a deletion script to run on the container
            echo "#!/bin/bash" > "$LOCAL_TEMP_DIR/delete_script.sh"
            echo "# Auto-generated file deletion script" >> "$LOCAL_TEMP_DIR/delete_script.sh"
            
            while IFS= read -r REL_PATH; do
                [ -z "$REL_PATH" ] && continue
                CONTAINER_PATH="${CONTAINER_MOUNT_DIR}/src/${REL_PATH}"
                echo "rm -f \"$CONTAINER_PATH\"" >> "$LOCAL_TEMP_DIR/delete_script.sh"
                if [ "$IS_VERBOSE" = true ]; then
                    log "Will delete: $CONTAINER_PATH"
                fi
            done < "$MANIFEST_DIR/files_to_delete.txt"
            
            # Make script executable
            chmod +x "$LOCAL_TEMP_DIR/delete_script.sh"
        fi
    else
        log "No files need to be deleted"
    fi
fi

# Flag to track if any files need updating
NEEDS_UPDATE=false

# Read local file manifest and check each file
while IFS= read -r LOCAL_FILE; do
    # Skip empty lines
    [ -z "$LOCAL_FILE" ] && continue
    
    # Calculate the corresponding container path
    if [[ "$LOCAL_FILE" == "./src/"* ]]; then
        # Handle paths that already include ./src/
        CONTAINER_FILE="${CONTAINER_MOUNT_DIR}${LOCAL_FILE#.}"
    else
        # Handle paths that don't include ./src/
        CONTAINER_FILE="${CONTAINER_MOUNT_DIR}/src/${LOCAL_FILE#./src/}"
    fi
    
    # Normalize paths to find in container_files.txt
    CONTAINER_PATH_NORMALIZED=$(echo "$CONTAINER_FILE" | sed 's/\/\//\//g')
    
    # Check if the file exists in the container
    if grep -q "$CONTAINER_PATH_NORMALIZED" "$MANIFEST_DIR/container_files.txt"; then
        if [ "$IS_VERBOSE" = true ]; then
            log "Found in container: $CONTAINER_PATH_NORMALIZED"
        fi
        
        # File exists in both local and container, check if we need to update
        # Since we can't easily compare timestamps between systems, add file to update list
        # This is a simplification - in a real implementation, you might want to compare file hashes
        RELATIVE_PATH="${LOCAL_FILE#./src/}"
        TARGET_DIR=$(dirname "$LOCAL_TEMP_DIR/update/$RELATIVE_PATH")
        mkdir -p "$TARGET_DIR"
        cp "$LOCAL_FILE" "$TARGET_DIR/"
        NEEDS_UPDATE=true
    else
        # File doesn't exist in container, always add to update list
        if [ "$IS_VERBOSE" = true ]; then
            log "New file: $LOCAL_FILE"
        fi
        RELATIVE_PATH="${LOCAL_FILE#./src/}"
        TARGET_DIR=$(dirname "$LOCAL_TEMP_DIR/update/$RELATIVE_PATH")
        mkdir -p "$TARGET_DIR"
        cp "$LOCAL_FILE" "$TARGET_DIR/"
        NEEDS_UPDATE=true
    fi
done < "$MANIFEST_DIR/local_files.txt"

# Check if we found any files that need updating
if [ "$NEEDS_UPDATE" = false ]; then
    log_warning "No files need to be updated"
    exit 0
fi

# Count files to update
UPDATE_COUNT=$(find "$LOCAL_TEMP_DIR/update" -type f | wc -l)
log "Found $UPDATE_COUNT files to update"

# In dry run mode, just show what would be updated and exit
if [ "$IS_DRY_RUN" = true ]; then
    log "DRY RUN - The following files would be updated:"
    find "$LOCAL_TEMP_DIR/update" -type f | sort
    log_success "Dry run completed. No files were modified."
    exit 0
fi

# Process deletions if we have files to delete
if [ "$IS_ALL" = true ] && [ -f "$LOCAL_TEMP_DIR/delete_script.sh" ] && [ "$DELETE_COUNT" -gt 0 ]; then
    log "Deleting $DELETE_COUNT files that don't exist locally..."
    
    # Transfer the deletion script to the TPU VM
    gcloud compute tpus tpu-vm scp \
        --zone="${TPU_ZONE}" \
        --project="${PROJECT_ID}" \
        "${LOCAL_TEMP_DIR}/delete_script.sh" \
        "${TPU_NAME}:${HOST_MOUNT_DIR}/"
    
    # Execute the deletion script in the container
    vmssh "
        chmod +x ${HOST_MOUNT_DIR}/delete_script.sh
        sudo docker cp ${HOST_MOUNT_DIR}/delete_script.sh ${CONTAINER_NAME}:/tmp/delete_script.sh
        sudo docker exec ${CONTAINER_NAME} chmod +x /tmp/delete_script.sh
        sudo docker exec ${CONTAINER_NAME} /tmp/delete_script.sh
        sudo docker exec ${CONTAINER_NAME} rm /tmp/delete_script.sh
        rm ${HOST_MOUNT_DIR}/delete_script.sh
    "
    
    log_success "File deletion completed"
fi

# Create a tar file of the files to update
TAR_FILE="${LOCAL_TEMP_DIR}/update.tar"
tar -cf "${TAR_FILE}" -C "${LOCAL_TEMP_DIR}/update" .

# Transfer the tar file to TPU VM
log "Transferring updated files to TPU VM..."
gcloud compute tpus tpu-vm scp \
    --zone="${TPU_ZONE}" \
    --project="${PROJECT_ID}" \
    "${TAR_FILE}" \
    "${TPU_NAME}:${HOST_MOUNT_DIR}/"

# Extract the tar file on the TPU VM and copy to container
log "Updating files in Docker container..."
vmssh "
    # Extract the tar file on the VM
    cd ${HOST_MOUNT_DIR} && tar -xf update.tar && rm update.tar
    
    # Create target directory structure in container
    sudo docker exec ${CONTAINER_NAME} mkdir -p ${CONTAINER_MOUNT_DIR}/src
    
    # Copy files from VM to container with proper path preservation
    if [ \"$IS_ALL\" = true ]; then
        # For --all, we want to copy everything to /app/mount/src with structure preserved
        sudo docker cp ${HOST_MOUNT_DIR}/. ${CONTAINER_NAME}:${CONTAINER_MOUNT_DIR}/src/
    else
        # For specific directory or file, copy to the appropriate target location
        if [ -d \"${HOST_MOUNT_DIR}/src\" ]; then
            # If there's a src directory, copy its contents to maintain isometry
            sudo docker cp ${HOST_MOUNT_DIR}/src/. ${CONTAINER_NAME}:${CONTAINER_MOUNT_DIR}/src/
        else
            # Otherwise copy everything to src
            sudo docker cp ${HOST_MOUNT_DIR}/. ${CONTAINER_NAME}:${CONTAINER_MOUNT_DIR}/src/
        fi
    fi
    
    # Set proper permissions
    sudo docker exec ${CONTAINER_NAME} chmod -R 777 ${CONTAINER_MOUNT_DIR}/src
"

# Final log and container inspection
if [ "$IS_ALL" = true ] && [ "$DELETE_COUNT" -gt 0 ]; then
    log_success "Successfully synced $UPDATE_COUNT files and deleted $DELETE_COUNT files in container"
else
    log_success "Successfully synced $UPDATE_COUNT files to container"
fi

# Optionally show the updated files in the container
if [ "$IS_VERBOSE" = true ]; then
    log "Updated files in container:"
    vmssh "echo 'Container contents after sync:'; sudo docker exec ${CONTAINER_NAME} find ${CONTAINER_MOUNT_DIR}/src -type f | sort"
fi

exit 0 