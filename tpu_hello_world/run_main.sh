#!/bin/bash

# Enable error handling and command tracing
set -e  # Exit on error
set -x  # Print commands as they are executed

# Function for logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function for error handling
handle_error() {
    local line_no=$1
    local error_code=$2
    log "ERROR: Command failed at line $line_no with exit code $error_code"
    exit $error_code
}

# Set up error trap
trap 'handle_error ${LINENO} $?' ERR

log "Starting main.py execution on TPU VM..."

# Load environment variables from .env file
log "Loading environment variables..."
source .env
log "Environment variables loaded successfully"

# Set the service account credentials
log "Setting up service account credentials..."
export GOOGLE_APPLICATION_CREDENTIALS="$SERVICE_ACCOUNT_JSON"

# Verify the credentials file exists
if [ ! -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    log "ERROR: Service account JSON file not found at $GOOGLE_APPLICATION_CREDENTIALS"
    log "Please ensure you have copied your service account JSON file to: $(pwd)/$SERVICE_ACCOUNT_JSON"
    exit 1
fi
log "Service account credentials file found"

# Authenticate with the service account
log "Authenticating with service account..."
gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
log "Service account authentication successful"

# Verify TPU VM exists before attempting to run
log "Verifying TPU VM exists..."
if ! gcloud compute tpus tpu-vm describe $TPU_NAME --zone=$ZONE --project=$PROJECT_ID > /dev/null 2>&1; then
    log "ERROR: TPU VM '$TPU_NAME' not found in zone $ZONE"
    log "Please run setup_tpu.sh first to create the TPU VM"
    exit 1
fi
log "TPU VM '$TPU_NAME' found and available"

# Verify SSH connection to TPU VM
log "Verifying SSH connection to TPU VM..."
if ! gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$ZONE --command="echo 'SSH connection test'" > /dev/null 2>&1; then
    log "ERROR: Failed to establish SSH connection to TPU VM"
    exit 1
fi
log "SSH connection verified"

# Run the main.py script on the TPU VM
log "Executing main.py on TPU VM..."
gcloud compute tpus tpu-vm ssh $TPU_NAME \
    --zone=$ZONE \
    --command="python3 main.py"
log "Script execution completed successfully"

log "All operations completed successfully." 