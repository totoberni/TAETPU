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

log "Starting TPU teardown process..."

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

# Verify TPU VM exists before attempting deletion
log "Verifying TPU VM exists..."
if gcloud compute tpus tpu-vm describe $TPU_NAME --zone=$ZONE --project=$PROJECT_ID > /dev/null 2>&1; then
    log "TPU VM '$TPU_NAME' found in zone $ZONE"
    
    # Delete the TPU VM
    log "Deleting TPU VM..."
    gcloud compute tpus tpu-vm delete $TPU_NAME \
        --zone=$ZONE \
        --project=$PROJECT_ID \
        --quiet
    log "TPU VM deletion completed"
else
    log "WARNING: TPU VM '$TPU_NAME' not found in zone $ZONE"
fi

# Optional: Check and delete the GCS bucket
log "Checking GCS bucket status..."
if gsutil ls -b gs://$BUCKET_NAME > /dev/null 2>&1; then
    log "GCS bucket 'gs://$BUCKET_NAME' exists"
    log "NOTE: Bucket deletion is commented out for safety. Uncomment the following lines to delete the bucket."
    # log "Deleting GCS bucket..."
    # gsutil rm -r gs://$BUCKET_NAME
    # log "GCS bucket deletion completed"
else
    log "GCS bucket 'gs://$BUCKET_NAME' not found"
fi

log "TPU Teardown process completed successfully." 