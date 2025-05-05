#!/bin/bash
set -e

# Source environment variables
source $(dirname "$0")/../utils/common.sh

# Initialize
init_script 'Run Script in Container'

# Check if a script path was provided
if [ $# -lt 1 ]; then
    log_error "Usage: $0 <script_path> [args...]"
    exit 1
fi

SCRIPT_PATH="$1"
shift  # Remove the script path from arguments

# Make sure SCRIPT_PATH is within the mount directory
if [[ "$SCRIPT_PATH" != *"/"* ]]; then
    SCRIPT_PATH="data/$SCRIPT_PATH"  # Default to data directory for simple filenames
fi

WORKING_DIR="${CONTAINER_MOUNT_DIR}/src"
FULL_SCRIPT_PATH="$WORKING_DIR/$SCRIPT_PATH"

log "Running script: $SCRIPT_PATH inside container"

# Run the script inside the container with proper working directory
gcloud compute tpus tpu-vm ssh ${TPU_NAME} \
    --zone=${TPU_ZONE} \
    --project=${PROJECT_ID} \
    --command="docker exec -w $WORKING_DIR ${CONTAINER_NAME} python $FULL_SCRIPT_PATH $@"

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    log_success "Script executed successfully"
else
    log_error "Script execution failed with exit code: $EXIT_CODE"
fi

exit $EXIT_CODE