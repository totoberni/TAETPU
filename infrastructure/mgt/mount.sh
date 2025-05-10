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
load_env_vars "$ENV_FILE" || exit 1

# Check required environment variables
check_env_vars "PROJECT_ID" "TPU_NAME" "TPU_ZONE" "CONTAINER_NAME" || exit 1

# Define common variables
function define_variables() {
    # Set defaults
    CONTAINER_MOUNT_DIR="${CONTAINER_MOUNT_DIR:-/app/mount}"
    HOST_MOUNT_DIR="${HOST_MOUNT_DIR:-mount}"
    
    # Flags
    IS_ALL=false
    IS_CONFIG=false
    IS_DIR=false
    TARGET_PATH=""
}

# Display usage instructions
function display_help() {
    echo "Usage: $0 <file_path> [--dir] OR $0 --all OR $0 --config"
    echo ""
    echo "Options:"
    echo "  --all: Mount the entire local ./src directory"
    echo "  --config: Mount the .env file to /app/mount/src/configs/.env"
    echo "  --dir: Optional flag to indicate copying a directory"
    echo ""
    echo "Examples:"
    echo "  $0 --all                 # Mount entire src directory"
    echo "  $0 --config              # Mount .env file to container"
    echo "  $0 example.py            # Mount a single file"
    echo "  $0 --dir src/data        # Mount a directory"
}

# Parse command-line arguments
function parse_arguments() {
    if [ $# -eq 0 ]; then
        log_error "No arguments provided."
        display_help
        exit 1
    fi

    # Check for flags
    for arg in "$@"; do
        case "$arg" in
            --all)
                IS_ALL=true
                ;;
            --config)
                IS_CONFIG=true
                ;;
            --dir)
                # This is handled later
                ;;
            --help|-h)
                display_help
                exit 0
                ;;
            *)
                if [[ "$arg" != "--dir" && "$TARGET_PATH" == "" ]]; then
                    TARGET_PATH="$arg"
                fi
                ;;
        esac
    done
    
    # Check for directory flag if we're not using --all or --config
    if [[ "$IS_ALL" == "false" && "$IS_CONFIG" == "false" && "$*" == *"--dir"* ]]; then
        IS_DIR=true
    fi
}

# Function to mount config file
function mount_config_file() {
    log "Mounting .env configuration file"
    
    # Create the configs directory structure in temp
    mkdir -p "$LOCAL_TEMP_DIR/src/configs"
    
    # Copy the .env file
    if [ -f "$ENV_FILE" ]; then
        cp "$ENV_FILE" "$LOCAL_TEMP_DIR/src/configs/.env"
        log "Prepared .env file for transfer"
    else
        log_error "Environment file not found: $ENV_FILE"
        exit 1
    fi
}

# Handle mounting the entire src directory
function mount_all() {
    log "Mounting entire local ./src directory"
    
    # Check if ./src directory exists
    if [ ! -d "./src" ]; then
        log_error "Local ./src directory not found"
        exit 1
    fi
    
    # Create src directory in temp dir to preserve structure
    mkdir -p "$LOCAL_TEMP_DIR/src"
    
    # Copy contents preserving structure
    cp -r "./src/"* "$LOCAL_TEMP_DIR/src/" || {
        log_error "Failed to copy src directory contents"
        exit 1
    }
    
    # Also copy the .env file to src/configs
    mkdir -p "$LOCAL_TEMP_DIR/src/configs"
    cp "$ENV_FILE" "$LOCAL_TEMP_DIR/src/configs/.env" || {
        log_warning "Could not copy .env file to src/configs"
    }
    
    log "Prepared local src directory structure for transfer"
}

# Handle mounting a specific file or directory
function mount_specific_path() {
    if [ ! -e "$TARGET_PATH" ]; then
        log_error "Path not found: $TARGET_PATH"
        exit 1
    fi

    if [ "$IS_DIR" = true ]; then
        if [ ! -d "$TARGET_PATH" ]; then
            log_error "Not a directory: $TARGET_PATH"
            exit 1
        fi
        log "Copying directory: $TARGET_PATH"
        mkdir -p "$LOCAL_TEMP_DIR/$(dirname "$TARGET_PATH")"
        cp -r "$TARGET_PATH" "$LOCAL_TEMP_DIR/$(dirname "$TARGET_PATH")/" || {
            log_error "Failed to copy directory: $TARGET_PATH"
            exit 1
        }
    else
        if [ ! -f "$TARGET_PATH" ]; then
            log_error "Not a file: $TARGET_PATH"
            exit 1
        fi
        log "Copying file: $TARGET_PATH"
        mkdir -p "$LOCAL_TEMP_DIR/$(dirname "$TARGET_PATH")"
        cp "$TARGET_PATH" "$LOCAL_TEMP_DIR/$(dirname "$TARGET_PATH")/" || {
            log_error "Failed to copy file: $TARGET_PATH"
            exit 1
        }
    fi
}

# Set the target directory in the container
function set_target_directory() {
    # Default target directory
    TARGET_DIR="${CONTAINER_MOUNT_DIR:-/app/mount}"
    
    # If mounting a specific path, determine the target directory
    if [ "$IS_ALL" = false ] && [ "$IS_CONFIG" = false ]; then
        if [[ "$TARGET_PATH" == *"/"* ]]; then
            # Extract directory path from TARGET_PATH
            DIR_PART=$(dirname "$TARGET_PATH")
            TARGET_DIR="${TARGET_DIR}/${DIR_PART}"
        fi
    fi
}

# Upload files to TPU VM
function upload_to_tpu() {
    log "Setting up remote directory on TPU VM"
    vmssh "mkdir -p ${HOST_MOUNT_DIR} && echo 'Remote directory created'"
    
    log "Uploading to TPU VM (project: ${PROJECT_ID}, zone: ${TPU_ZONE}, TPU: ${TPU_NAME})"
    
    if [ -n "$(ls -A "${LOCAL_TEMP_DIR}")" ]; then
        # Debug info
        log "Files to transfer:"
        ls -la "${LOCAL_TEMP_DIR}"

        # Use direct gcloud command with --recurse flag to preserve directory structure
        log "Transferring files with directory structure preserved"
        gcloud compute tpus tpu-vm scp \
            --recurse \
            --zone="${TPU_ZONE}" \
            --project="${PROJECT_ID}" \
            "${LOCAL_TEMP_DIR}/"* \
            "${TPU_NAME}:${HOST_MOUNT_DIR}/"
        
        local exit_code=$?
        if [ $exit_code -ne 0 ]; then
            log_error "Failed to transfer files to TPU VM (exit code: $exit_code)"
            return 1
        fi
        
        log_success "Files transferred to TPU VM with directory structure preserved"
    else
        log_warning "No files found to upload in ${LOCAL_TEMP_DIR}"
        return 1
    fi
}

# Copy files from TPU VM to Docker container
function copy_to_container() {
    log "Copying into Docker container (${CONTAINER_NAME})"
    
    # Command to copy files from VM to container
    local docker_cp_cmd="
        # Create target directory structure in container
        sudo docker exec ${CONTAINER_NAME} mkdir -p ${CONTAINER_MOUNT_DIR:-/app/mount}
        
        # Copy files from VM to container with proper path preservation
        if [ \"$IS_ALL\" = true ] || [ \"$IS_CONFIG\" = true ]; then
            # For --all or --config, copy with structure maintained
            sudo docker cp ${HOST_MOUNT_DIR}/. ${CONTAINER_NAME}:${CONTAINER_MOUNT_DIR:-/app/mount}/
        else
            # For specific files/dirs, respect the target directory structure
            sudo docker cp ${HOST_MOUNT_DIR}/. ${CONTAINER_NAME}:$TARGET_DIR/
        fi
        
        # Set proper permissions
        sudo docker exec ${CONTAINER_NAME} chmod -R 777 ${CONTAINER_MOUNT_DIR:-/app/mount}
        
        # Verify config file exists if applicable
        if [ \"$IS_CONFIG\" = true ]; then
            if sudo docker exec ${CONTAINER_NAME} [ -f ${CONTAINER_MOUNT_DIR}/src/configs/.env ]; then
                echo \"Config file successfully mounted\"
            else
                echo \"Warning: Config file not found in container\"
            fi
        fi
    "
    
    vmssh "$docker_cp_cmd" || {
        log_error "Failed to copy files into Docker container"
        return 1
    }
}

# Report success with appropriate message
function report_success() {
    if [ "$IS_ALL" = true ]; then
        log_success "Successfully mounted entire ./src directory to container"
        vmssh "echo 'Container contents after mount:'; sudo docker exec ${CONTAINER_NAME} ls -la ${CONTAINER_MOUNT_DIR}"
    elif [ "$IS_CONFIG" = true ]; then
        log_success "Successfully mounted .env configuration file to container"
        vmssh "echo 'Config file mounted at:'; sudo docker exec ${CONTAINER_NAME} ls -la ${CONTAINER_MOUNT_DIR}/src/configs/"
    else
        log_success "Successfully mounted $([ "$IS_DIR" = true ] && echo "directory" || echo "file"): $TARGET_PATH"
    fi
}

# Main function to orchestrate execution
function main() {
    define_variables
    parse_arguments "$@"
    
    # Create local temp directory for staging files, compatible with Windows environments
    LOCAL_TEMP_DIR="$PROJECT_DIR/tmp_mount_$(date +%s)"
    mkdir -p "$LOCAL_TEMP_DIR"
    trap "rm -rf '$LOCAL_TEMP_DIR'" EXIT
    
    log "Created temporary directory: $LOCAL_TEMP_DIR"
    
    # Prepare files for transfer
    if [ "$IS_ALL" = true ]; then
        mount_all
    elif [ "$IS_CONFIG" = true ]; then
        mount_config_file
    else
        mount_specific_path
    fi
    
    # Set target directory in container
    set_target_directory
    
    # Upload files to TPU VM and then to container
    upload_to_tpu && copy_to_container && report_success
}

# Execute main function
main "$@"
exit $?