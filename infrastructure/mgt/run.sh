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

# Check if a script path was provided
if [ $# -lt 1 ]; then
    log_error "Usage: $0 <script_path> [args...]"
    log_error "Example: $0 data/data_pipeline.py --model all"
    exit 1
fi

SCRIPT_PATH="$1"
shift  # Remove the script path from arguments

# Make sure SCRIPT_PATH is within the mount directory
if [[ "$SCRIPT_PATH" != *"/"* ]]; then
    SCRIPT_PATH="data/$SCRIPT_PATH"  # Default to data directory for simple filenames
fi

# Determine the working directory and full script path
WORKING_DIR="${CONTAINER_MOUNT_DIR:-/app/mount}/src"
FULL_SCRIPT_PATH="$WORKING_DIR/$SCRIPT_PATH"

log "Running script: $SCRIPT_PATH inside container (project: ${PROJECT_ID}, zone: ${TPU_ZONE}, TPU: ${TPU_NAME})"

# Run the script inside the container with proper working directory using vmssh function
COMMAND="
    # Verify script exists in container
    if ! docker exec ${CONTAINER_NAME} test -f $FULL_SCRIPT_PATH; then
        echo \"Error: Script $FULL_SCRIPT_PATH not found in container\"
        exit 1
    fi
    
    # Execute script with arguments
    docker exec -w $WORKING_DIR ${CONTAINER_NAME} python $FULL_SCRIPT_PATH $@
"

vmssh "$COMMAND"
EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    log_success "Script executed successfully"
else
    log_error "Script execution failed with exit code: $EXIT_CODE"
fi

exit $EXIT_CODE