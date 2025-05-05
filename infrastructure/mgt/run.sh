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
    log_error "Example: $0 example.py --arg value"
    exit 1
fi

SCRIPT_PATH="$1"
shift  # Remove the script path from arguments

# Set container paths - use same variable pattern as mount.sh
CONTAINER_MOUNT_DIR="${CONTAINER_MOUNT_DIR:-/app/mount}"
SRC_DIR="${CONTAINER_MOUNT_DIR}/src"

# Try to find the script in multiple locations
# 1. As provided (might be a full path like 'data/example.py')
# 2. Directly in src/ directory
# 3. In src/data/ directory (for backward compatibility)
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
        if docker exec ${CONTAINER_NAME} test -f \"\$path\"; then
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
        docker exec -w \"\$SCRIPT_DIR\" ${CONTAINER_NAME} python \"\$SCRIPT_LOCATION\" $@
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
    log_error "Make sure the script exists in the container and was properly mounted with mount.sh"
    log_error "Try: ./infrastructure/mgt/mount.sh --all"
fi

exit $EXIT_CODE