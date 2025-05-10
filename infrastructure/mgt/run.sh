#!/bin/bash
set -e

# Get the project directory (2 levels up from this script)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/../.." &> /dev/null && pwd )"
ENV_FILE="$PROJECT_DIR/config/.env"

# Source common utilities
source "$SCRIPT_DIR/../utils/common.sh"

# Initialize
init_script 'Run Script in Container'

# Load environment variables from .env file
load_env_vars "$ENV_FILE" || exit 1

# Check required environment variables
check_env_vars "PROJECT_ID" "TPU_NAME" "TPU_ZONE" "CONTAINER_NAME" || exit 1

# Define common variables
function define_variables() {
    CONTAINER_MOUNT_DIR="${CONTAINER_MOUNT_DIR:-/app/mount}"
    SRC_DIR="${CONTAINER_MOUNT_DIR}/src"
    
    USE_COMMAND=false
    COMMAND=""
    WORKDIR="${CONTAINER_MOUNT_DIR}"
    INTERACTIVE=false
    CUSTOM_DIR=""
    SCRIPT_PATH=""
}

# Parse command-line arguments
function parse_arguments() {
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            --command)
                USE_COMMAND=true
                if [[ -z "$2" || "$2" == --* ]]; then
                    log_error "The --command flag requires a command argument."
                    exit 1
                fi
                COMMAND="$2"
                shift 2
                
                # Check if a directory is provided as the next argument
                if [[ "$#" -gt 0 && "$1" != --* ]]; then
                    CUSTOM_DIR="$1"
                    shift
                fi
                ;;
            --interactive|-i)
                INTERACTIVE=true
                shift
                ;;
            --help|-h)
                display_help
                exit 0
                ;;
            *)
                if [ "$USE_COMMAND" = false ]; then
                    SCRIPT_PATH="$1"
                    shift  # Remove the script path from arguments
                    break  # The rest are script arguments
                else
                    shift  # Skip any extra arguments when using --command
                fi
                ;;
        esac
    done
    
    # Store remaining arguments
    SCRIPT_ARGS="$@"
}

# Display help message
function display_help() {
    echo "Usage: $0 [OPTIONS] <script_path> [script_args...]"
    echo "   or: $0 --command \"<command>\" [directory]"
    echo ""
    echo "Options:"
    echo "  --command \"CMD\" [DIR]  Execute a shell command in the container"
    echo "                        Optional DIR parameter to specify working directory"
    echo "                        (relative to /app/mount inside container)"
    echo "  --interactive, -i     Run command in interactive mode (with -it flags)"
    echo "  --help, -h            Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 example.py --arg value              # Run a Python script"
    echo "  $0 --command \"ls -la\"                 # List files in /app/mount"
    echo "  $0 --command \"cat data_config.yaml\" configs  # View a config file"
    echo "  $0 --command \"find . -name \\\"*.py\\\"\" src  # Find Python files in src"
    echo "  $0 --interactive --command \"bash\" src  # Start an interactive shell in src"
}

# Process directory path and normalize it
function process_directory() {
    if [ -z "$CUSTOM_DIR" ]; then
        return
    fi
    
    log "Processing directory: $CUSTOM_DIR"
    
    # Normalize path handling - always treat as a path relative to CONTAINER_MOUNT_DIR 
    # unless it's already a full container path
    if [[ "$CUSTOM_DIR" == "${CONTAINER_MOUNT_DIR}"* ]]; then
        # This is already a full container path, use as is
        WORKDIR="$CUSTOM_DIR"
    elif [[ "$CUSTOM_DIR" == /* ]]; then
        # This is an absolute path but not starting with the container mount dir
        # Let's assume user wants to use it as is (internal container path)
        WORKDIR="$CUSTOM_DIR"
        log_warning "Using absolute container path: $WORKDIR"
    else
        # This is a relative path, append to container mount dir
        WORKDIR="${CONTAINER_MOUNT_DIR}/${CUSTOM_DIR}"
    fi
    
    log "Using working directory: $WORKDIR"
}

# Execute a command in the container
function execute_command() {
    log "Executing command in container: $COMMAND"
    
    # Build the docker exec command with proper flags
    local docker_flags=""
    if [ "$INTERACTIVE" = true ]; then
        docker_flags="-it"
    fi
    
    # Define the Docker exec command
    local docker_cmd="sudo docker exec ${docker_flags} -w \"${WORKDIR}\" ${CONTAINER_NAME} bash -c \"${COMMAND}\""
    
    # Execute the command on the TPU VM using direct gcloud command for both modes
    log "Running command via gcloud..."
    gcloud compute tpus tpu-vm ssh ${TPU_NAME} \
        --zone="${TPU_ZONE}" \
        --project="${PROJECT_ID}" \
        --command="$docker_cmd"
    
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        log_success "Command executed successfully"
    else
        log_error "Command execution failed with exit code: $exit_code"
        log_error "If you specified a custom directory, make sure it exists in the container."
        log_error "You can list available directories with: $0 --command \"ls -la\""
    fi
    
    return $exit_code
}

# Run a Python script in the container
function execute_script() {
    if [ -z "${SCRIPT_PATH}" ]; then
        log_error "No script path provided."
        display_help
        exit 1
    fi

    # Try to find the script in multiple locations
    log "Running script: ${SCRIPT_PATH} inside container"
    
    # Possible script locations
    local script_paths=(
        "${SRC_DIR}/${SCRIPT_PATH}"
        "${SRC_DIR}/data/${SCRIPT_PATH}"
    )

    log "Will check these locations: ${script_paths[0]}, ${script_paths[1]}"

    # Create a command to find and execute the script
    local find_script_cmd="
        # Try to find the script in possible locations
        SCRIPT_FOUND=false
        SCRIPT_LOCATION=\"\"
        
        for path in \"${script_paths[0]}\" \"${script_paths[1]}\"; do
            if sudo docker exec ${CONTAINER_NAME} test -f \"\$path\"; then
                SCRIPT_FOUND=true
                SCRIPT_LOCATION=\"\$path\"
                break
            fi
        done
        
        if [ \"\$SCRIPT_FOUND\" = \"true\" ]; then
            echo \"Found script at: \$SCRIPT_LOCATION\"
            # Get the directory path for setting working directory
            SCRIPT_DIR=\$(dirname \"\$SCRIPT_LOCATION\")
            
            # Execute script with arguments
            sudo docker exec -w \"\$SCRIPT_DIR\" ${CONTAINER_NAME} python \"\$SCRIPT_LOCATION\" ${SCRIPT_ARGS}
        else
            echo \"Error: Script not found in any of these locations:\"
            echo \"  - ${script_paths[0]}\"
            echo \"  - ${script_paths[1]}\"
            echo \"Please make sure the file exists and was properly mounted with mount.sh\"
            exit 1
        fi
    "

    # Execute the command on the TPU VM
    vmssh "$find_script_cmd"
    
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log_success "Script executed successfully"
    else
        log_error "Script execution failed with exit code: $exit_code"
        log_error "Make sure the script exists in the container and was properly mounted with mount.sh"
        log_error "Try: ./infrastructure/mgt/mount.sh --all"
    fi

    return $exit_code
}

# Main function to orchestrate execution
function main() {
    define_variables
    parse_arguments "$@"
    
    if [ "$USE_COMMAND" = true ]; then
        process_directory
        execute_command
    else
        execute_script
    fi
}

# Execute main function
main "$@"
exit $?