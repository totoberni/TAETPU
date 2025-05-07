#!/bin/bash
set -e

# Get the project directory (2 levels up from this script)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/../.." &> /dev/null && pwd )"
ENV_FILE="$PROJECT_DIR/config/.env"

# Source common utilities
source "$SCRIPT_DIR/../utils/common.sh"

# Initialize
init_script 'Remove Files from Docker Container'

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
SCRAP_ALL=false
SCRAP_DIR=""
SPECIFIC_FILES=()

if [ $# -eq 0 ]; then
    log_error "Usage: $0 [--all] [--dir directory] [file1.py file2.py ...]"
    log_error "  --all: Remove all files from /app/mount/ directory (completely clean)"
    log_error "  --dir DIRECTORY: Remove a specific directory"
    log_error "  file1.py file2.py: Remove specific files"
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --all) SCRAP_ALL=true; shift ;;
        --dir)
            SCRAP_DIR="$2"
            shift 2
            ;;
        -h|--help)
            log_error "Usage: $0 [--all] [--dir directory] [file1.py file2.py ...]"
            log_error "  --all: Remove all files from /app/mount/ directory (completely clean)"
            log_error "  --dir DIRECTORY: Remove a specific directory"
            log_error "  file1.py file2.py: Remove specific files"
            exit 0
            ;;
        *) SPECIFIC_FILES+=("$1"); shift ;;
    esac
done

# Target container directory - use same variable pattern as mount.sh
CONTAINER_MOUNT_DIR="${CONTAINER_MOUNT_DIR:-/app/mount}"

# Check if TPU VM is accessible
log "Checking TPU VM connection (project: ${PROJECT_ID}, zone: ${TPU_ZONE}, TPU: ${TPU_NAME})..."
vmssh "echo 'TPU VM connection successful'" || { log_error "Failed to connect to TPU VM. Check your configuration."; exit 1; }

# Check if Docker container is running
log "Checking Docker container status (${CONTAINER_NAME})..."
vmssh "sudo docker ps | grep -q ${CONTAINER_NAME}" || { log_error "Container ${CONTAINER_NAME} is not running on TPU VM."; exit 1; }

# Handle different removal scenarios
if [ "$SCRAP_ALL" = true ]; then
    log "Preparing to remove ALL files from ${CONTAINER_MOUNT_DIR}..."
    
    # Ask for confirmation
    if ! confirm_delete "all $FILE_COUNT files from ${CONTAINER_MOUNT_DIR}"; then
        log_warning "Operation cancelled by user"
        exit 0
    fi
    
    # Simple, direct command to remove everything in /app/mount while preserving the mount dir itself
    vmssh "
        # Remove all contents but preserve the mount directory itself
        sudo docker exec ${CONTAINER_NAME} find ${CONTAINER_MOUNT_DIR} -mindepth 1 -delete 2>/dev/null || echo 'Some files could not be deleted'
        
        # Verify the directory is empty but still exists
        sudo docker exec ${CONTAINER_NAME} mkdir -p ${CONTAINER_MOUNT_DIR}
        
        echo 'All contents removed from ${CONTAINER_MOUNT_DIR}'
    "
    
    log_success "All files removed from container mount directory"

elif [ -n "$SCRAP_DIR" ]; then
    log "Preparing to remove directory: ${SCRAP_DIR} from container..."
    
    # For directories, ensure we target the correct path in src/
    TARGET_PATH="${CONTAINER_MOUNT_DIR}/src/${SCRAP_DIR}"
    
    # Ask for confirmation
    if ! confirm_delete "directory '${SCRAP_DIR}' and its contents"; then
        log_warning "Operation cancelled by user"
        exit 0
    fi
    
    vmssh "
        if sudo docker exec ${CONTAINER_NAME} test -d ${TARGET_PATH}; then
            # Remove directory and its contents
            sudo docker exec ${CONTAINER_NAME} rm -rf ${TARGET_PATH}
            echo 'Directory ${SCRAP_DIR} removed'
        else
            echo 'Directory not found: ${TARGET_PATH}'
        fi
    "
    
    log_success "Directory ${SCRAP_DIR} removed from container"

elif [ ${#SPECIFIC_FILES[@]} -gt 0 ]; then
    log "Preparing to remove specific files..."
    
    # Show list of files to be removed
    echo "The following files will be removed:"
    for file in "${SPECIFIC_FILES[@]}"; do
        echo "  - ${file}"
    done
    
    # Ask for confirmation
    if ! confirm_delete "${#SPECIFIC_FILES[@]} files"; then
        log_warning "Operation cancelled by user"
        exit 0
    fi
    
    for file in "${SPECIFIC_FILES[@]}"; do
        # Ensure proper path to file in src directory
        TARGET_PATH="${CONTAINER_MOUNT_DIR}/src/${file}"
        
        vmssh "
            if sudo docker exec ${CONTAINER_NAME} test -f ${TARGET_PATH}; then
                sudo docker exec ${CONTAINER_NAME} rm -f ${TARGET_PATH}
                echo 'Removed file: ${file}'
            elif sudo docker exec ${CONTAINER_NAME} test -d ${TARGET_PATH}; then
                sudo docker exec ${CONTAINER_NAME} rm -rf ${TARGET_PATH}
                echo 'Removed directory: ${file} and its contents'
            else
                echo 'File or directory not found: ${file}'
            fi
        "
    done
    
    log_success "Specified files removed from container"
fi

# Verify current state (optional)
log "Current container mount directory state:"
vmssh "echo 'Container contents after scrap:'; sudo docker exec ${CONTAINER_NAME} ls -la ${CONTAINER_MOUNT_DIR}"

exit 0