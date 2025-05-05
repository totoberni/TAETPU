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
    log_error "  --all: Remove all files from /app/mount/ directory"
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
            log_error "  --all: Remove all files from /app/mount/ directory"
            log_error "  --dir DIRECTORY: Remove a specific directory"
            log_error "  file1.py file2.py: Remove specific files"
            exit 0
            ;;
        *) SPECIFIC_FILES+=("$1"); shift ;;
    esac
done

# Target container directory
CONTAINER_DIR="/app/mount"

# Check if TPU VM is accessible
log "Checking TPU VM connection (project: ${PROJECT_ID}, zone: ${TPU_ZONE}, TPU: ${TPU_NAME})..."
vmssh "echo 'TPU VM connection successful'" || { log_error "Failed to connect to TPU VM. Check your configuration."; exit 1; }

# Check if Docker container is running
log "Checking Docker container status (${CONTAINER_NAME})..."
vmssh "docker ps | grep -q ${CONTAINER_NAME}" || { log_error "Container ${CONTAINER_NAME} is not running on TPU VM."; exit 1; }

# Handle different removal scenarios
if [ "$SCRAP_ALL" = true ]; then
    log "Removing ALL files from ${CONTAINER_DIR}..."
    
    # No validation, just remove everything from /app/mount/
    vmssh "
        docker exec ${CONTAINER_NAME} rm -rf ${CONTAINER_DIR}/*
        docker exec ${CONTAINER_NAME} mkdir -p ${CONTAINER_DIR}/src
        echo 'All files removed from ${CONTAINER_DIR}/'
    "
    
    log_success "All files removed from container mount directory"

elif [ -n "$SCRAP_DIR" ]; then
    log "Removing directory: ${SCRAP_DIR} from container..."
    
    vmssh "
        docker exec ${CONTAINER_NAME} rm -rf ${CONTAINER_DIR}/${SCRAP_DIR}
        echo 'Directory ${SCRAP_DIR} removed'
    "
    
    log_success "Directory ${SCRAP_DIR} removed from container"

elif [ ${#SPECIFIC_FILES[@]} -gt 0 ]; then
    log "Removing specific files..."
    
    for file in "${SPECIFIC_FILES[@]}"; do
        vmssh "
            if docker exec ${CONTAINER_NAME} test -f ${CONTAINER_DIR}/${file}; then
                docker exec ${CONTAINER_NAME} rm -f ${CONTAINER_DIR}/${file}
                echo 'Removed file: ${file}'
            else
                echo 'File not found: ${file}'
            fi
        "
    done
    
    log_success "Specified files removed from container"
fi

# Verify current state (optional)
log "Current container mount directory state:"
vmssh "docker exec ${CONTAINER_NAME} ls -la ${CONTAINER_DIR}"

exit 0