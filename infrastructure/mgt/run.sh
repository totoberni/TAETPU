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

# Set container paths - use same variable pattern as mount.sh
CONTAINER_MOUNT_DIR="${CONTAINER_MOUNT_DIR:-/app/mount}"
SRC_DIR="${CONTAINER_MOUNT_DIR}/src"  # Update to use /src directory for isometry

# Check if we're running a shell command
USE_COMMAND=false
COMMAND=""
WORKDIR="${CONTAINER_MOUNT_DIR}"  # Default to app/mount as root
INTERACTIVE=false
CUSTOM_DIR=""

# Process arguments
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
            echo ""
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

if [ "$USE_COMMAND" = true ]; then
    # Handle custom directory if provided
    if [ -n "$CUSTOM_DIR" ]; then
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
    fi
    
    log "Executing command in container: $COMMAND"
    
    # Build the docker exec command with proper flags
    DOCKER_FLAGS=""
    if [ "$INTERACTIVE" = true ]; then
        DOCKER_FLAGS="-it"
    fi
    
    # Define the SSH command that will run docker exec on the TPU VM
    # No directory validation to avoid hangs - Docker will error if directory doesn't exist
    SSH_COMMAND="sudo docker exec ${DOCKER_FLAGS} -w \"${WORKDIR}\" ${CONTAINER_NAME} bash -c \"${COMMAND}\""
    
    # Execute the command on the TPU VM
    if [ "$INTERACTIVE" = true ]; then
        # For interactive sessions, use a simpler approach to avoid tty issues
        log "Starting interactive session in directory: $WORKDIR"
        gcloud compute tpus tpu-vm ssh ${TPU_NAME} \
            --zone="${TPU_ZONE}" \
            --project="${PROJECT_ID}" \
            --command="sudo docker exec -it -w \"${WORKDIR}\" ${CONTAINER_NAME} bash -c \"${COMMAND}\""
    else
        # For non-interactive commands, use direct gcloud command instead of vmssh
        log "Running command via gcloud..."
        gcloud compute tpus tpu-vm ssh ${TPU_NAME} \
            --zone="${TPU_ZONE}" \
            --project="${PROJECT_ID}" \
            --command="$SSH_COMMAND"
    fi
    
    EXIT_CODE=$?
    
    if [ $EXIT_CODE -eq 0 ]; then
        log_success "Command executed successfully"
    else
        log_error "Command execution failed with exit code: $EXIT_CODE"
        log_error "If you specified a custom directory, make sure it exists in the container."
        log_error "You can list available directories with: $0 --command \"ls -la\""
    fi
    
    exit $EXIT_CODE
else
    # Check if a script path was provided
    if [ -z "${SCRIPT_PATH}" ]; then
        log_error "Usage: $0 <script_path> [args...] or $0 --command \"<command>\" [directory]"
        log_error "Example: $0 example.py --arg value"
        log_error "Use $0 --help for more information"
        exit 1
    fi

    # Try to find the script in multiple locations
    # 1. As provided (might be a full path like 'data/example.py')
    # 2. In src/data/ directory (for backward compatibility)
    SCRIPT_PATHS=(
        "${SRC_DIR}/${SCRIPT_PATH}"
        "${SRC_DIR}/data/${SCRIPT_PATH}"
    )

    log "Running script: ${SCRIPT_PATH} inside container"
    log "Will check these locations: ${SCRIPT_PATHS[0]}, ${SCRIPT_PATHS[1]}"

    # Command to find and execute the script
    COMMAND="
        # Try to find the script in possible locations
        SCRIPT_FOUND=false
        SCRIPT_LOCATION=\"\"
        
        for path in \"${SCRIPT_PATHS[0]}\" \"${SCRIPT_PATHS[1]}\"; do
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
            sudo docker exec -w \"\$SCRIPT_DIR\" ${CONTAINER_NAME} python \"\$SCRIPT_LOCATION\" $@
        else
            echo \"Error: Script not found in any of these locations:\"
            echo \"  - ${SCRIPT_PATHS[0]}\"
            echo \"  - ${SCRIPT_PATHS[1]}\"
            echo \"Please make sure the file exists and was properly mounted with mount.sh\"
            exit 1
        fi
    "

    # Execute the command on the TPU VM
    gcloud compute tpus tpu-vm ssh ${TPU_NAME} \
        --zone="${TPU_ZONE}" \
        --project="${PROJECT_ID}" \
        --command="$COMMAND"

    EXIT_CODE=$?

    if [ $EXIT_CODE -eq 0 ]; then
        log_success "Script executed successfully"
    else
        log_error "Script execution failed with exit code: $EXIT_CODE"
        log_error "Make sure the script exists in the container's /app/mount/src directory and was properly mounted with mount.sh"
        log_error "Try: ./infrastructure/mgt/mount.sh --all"
    fi

    exit $EXIT_CODE
fi