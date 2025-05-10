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
load_env_vars "$ENV_FILE" || exit 1

# Check required environment variables
check_env_vars "PROJECT_ID" "TPU_NAME" "TPU_ZONE" "CONTAINER_NAME" || exit 1

# Define common variables
function define_variables() {
    # Set container paths
    CONTAINER_MOUNT_DIR="${CONTAINER_MOUNT_DIR:-/app/mount}"
    
    # Operation flags
    SCRAP_ALL=false
    SCRAP_DIR=""
    SPECIFIC_FILES=()
}

# Display help message
function display_help() {
    echo "Usage: $0 [--all] [--dir directory] [file1.py file2.py ...]"
    echo ""
    echo "Options:"
    echo "  --all: Remove all files from /app/mount/ directory (completely clean)"
    echo "  --dir DIRECTORY: Remove a specific directory"
    echo "  file1.py file2.py: Remove specific files"
    echo ""
    echo "Examples:"
    echo "  $0 --all                 # Clear all files in container"
    echo "  $0 --dir cache           # Remove a specific directory"
    echo "  $0 example.py config.py  # Remove specific files"
}

# Parse command-line arguments
function parse_arguments() {
    if [ $# -eq 0 ]; then
        log_error "No arguments provided."
        display_help
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --all) 
                SCRAP_ALL=true
                shift 
                ;;
            --dir)
                if [[ -z "$2" || "$2" == --* ]]; then
                    log_error "The --dir flag requires a directory name."
                    exit 1
                fi
                SCRAP_DIR="$2"
                shift 2
                ;;
            -h|--help)
                display_help
                exit 0
                ;;
            *) 
                SPECIFIC_FILES+=("$1")
                shift 
                ;;
        esac
    done
    
    # Validate arguments
    if [ "$SCRAP_ALL" = false ] && [ -z "$SCRAP_DIR" ] && [ ${#SPECIFIC_FILES[@]} -eq 0 ]; then
        log_error "No removal targets specified."
        display_help
        exit 1
    fi
}

# Check connectivity to TPU VM and Docker container
function check_connectivity() {
    # Check if TPU VM is accessible
    log "Checking TPU VM connection (project: ${PROJECT_ID}, zone: ${TPU_ZONE}, TPU: ${TPU_NAME})..."
    vmssh "echo 'TPU VM connection successful'" || { 
        log_error "Failed to connect to TPU VM. Check your configuration."
        exit 1
    }
    
    # Check if Docker container is running
    log "Checking Docker container status (${CONTAINER_NAME})..."
    vmssh "sudo docker ps | grep -q ${CONTAINER_NAME}" || { 
        log_error "Container ${CONTAINER_NAME} is not running on TPU VM."
        exit 1
    }
}

# Remove all files from container mount directory
function remove_all_files() {
    log "Preparing to remove ALL files from ${CONTAINER_MOUNT_DIR}..."
    
    # Ask for confirmation
    if ! confirm_delete "all files from ${CONTAINER_MOUNT_DIR}"; then
        log_warning "Operation cancelled by user"
        return 1
    fi
    
    # Command to remove everything in mount dir while preserving the mount dir itself
    local cmd="
        # Remove all contents but preserve the mount directory itself
        sudo docker exec ${CONTAINER_NAME} find ${CONTAINER_MOUNT_DIR} -mindepth 1 -delete 2>/dev/null || echo 'Some files could not be deleted'
        
        # Verify the directory is empty but still exists
        sudo docker exec ${CONTAINER_NAME} mkdir -p ${CONTAINER_MOUNT_DIR}
        
        echo 'All contents removed from ${CONTAINER_MOUNT_DIR}'
    "
    
    vmssh "$cmd" || {
        log_error "Failed to remove all files from container"
        return 1
    }
    
    log_success "All files removed from container mount directory"
    return 0
}

# Remove a specific directory
function remove_directory() {
    log "Preparing to remove directory: ${SCRAP_DIR} from container..."
    
    # For directories, ensure we target the correct path in src/
    local target_path="${CONTAINER_MOUNT_DIR}/src/${SCRAP_DIR}"
    
    # Ask for confirmation
    if ! confirm_delete "directory '${SCRAP_DIR}' and its contents"; then
        log_warning "Operation cancelled by user"
        return 1
    fi
    
    # Command to remove the directory
    local cmd="
        if sudo docker exec ${CONTAINER_NAME} test -d ${target_path}; then
            # Remove directory and its contents
            sudo docker exec ${CONTAINER_NAME} rm -rf ${target_path}
            echo 'Directory ${SCRAP_DIR} removed'
        else
            echo 'Directory not found: ${target_path}'
            exit 1
        fi
    "
    
    vmssh "$cmd" || {
        log_warning "Directory may not exist in container"
        return 1
    }
    
    log_success "Directory ${SCRAP_DIR} removed from container"
    return 0
}

# Remove specific files
function remove_specific_files() {
    log "Preparing to remove specific files..."
    
    # Show list of files to be removed
    echo "The following files will be removed:"
    for file in "${SPECIFIC_FILES[@]}"; do
        echo "  - ${file}"
    done
    
    # Ask for confirmation
    if ! confirm_delete "${#SPECIFIC_FILES[@]} files"; then
        log_warning "Operation cancelled by user"
        return 1
    fi
    
    local success=true
    
    for file in "${SPECIFIC_FILES[@]}"; do
        # Ensure proper path to file in src directory
        local target_path="${CONTAINER_MOUNT_DIR}/src/${file}"
        
        # Command to remove the file or directory
        local cmd="
            if sudo docker exec ${CONTAINER_NAME} test -f ${target_path}; then
                sudo docker exec ${CONTAINER_NAME} rm -f ${target_path}
                echo 'Removed file: ${file}'
            elif sudo docker exec ${CONTAINER_NAME} test -d ${target_path}; then
                sudo docker exec ${CONTAINER_NAME} rm -rf ${target_path}
                echo 'Removed directory: ${file} and its contents'
            else
                echo 'File or directory not found: ${file}'
                exit 1
            fi
        "
        
        vmssh "$cmd" || {
            log_warning "File or directory not found: ${file}"
            success=false
        }
    done
    
    if [ "$success" = true ]; then
        log_success "Specified files removed from container"
        return 0
    else
        log_warning "Some files could not be removed"
        return 1
    fi
}

# Show current directory state
function show_directory_state() {
    log "Current container mount directory state:"
    vmssh "echo 'Container contents after scrap:'; sudo docker exec ${CONTAINER_NAME} ls -la ${CONTAINER_MOUNT_DIR}" || {
        log_warning "Could not list container directory contents"
    }
}

# Main function
function main() {
    define_variables
    parse_arguments "$@"
    check_connectivity
    
    # Handle different removal scenarios
    local success=true
    
    if [ "$SCRAP_ALL" = true ]; then
        remove_all_files || success=false
    elif [ -n "$SCRAP_DIR" ]; then
        remove_directory || success=false
    elif [ ${#SPECIFIC_FILES[@]} -gt 0 ]; then
        remove_specific_files || success=false
    fi
    
    # Show final directory state
    show_directory_state
    
    # Return appropriate exit code
    if [ "$success" = true ]; then
        return 0
    else
        return 1
    fi
}

# Run main function
main "$@"
exit $?