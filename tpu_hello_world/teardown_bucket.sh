#!/bin/bash

# --- HELPER FUNCTIONS ---
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1"
}

handle_error() {
    local line_no=$1
    local error_code=$2
    log "ERROR: Command failed at line $line_no with exit code $error_code"
    exit $error_code
}

# Set up error trapping
trap 'handle_error ${LINENO} $?' ERR

# --- MAIN SCRIPT ---
log 'Starting GCS bucket teardown process...'

log 'Loading environment variables...'
source .env
log 'Environment variables loaded successfully'

log 'Setting up service account credentials...'
export GOOGLE_APPLICATION_CREDENTIALS="$(pwd)/$SERVICE_ACCOUNT_JSON"

if [ ! -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    log "ERROR: Service account credentials file not found at: $GOOGLE_APPLICATION_CREDENTIALS"
    exit 1
fi
log 'Service account credentials file found'

log 'Authenticating with service account...'
gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
log 'Service account authentication successful'

# Check if bucket exists
log "Checking if bucket exists..."
if ! gsutil ls -b "gs://$BUCKET_NAME" &> /dev/null; then
    log "Bucket '$BUCKET_NAME' does not exist. Nothing to delete."
    exit 0
fi
log "Bucket '$BUCKET_NAME' found"

# Disable command tracing for the prompt
set +x
read -r -p "Do you want to delete the GCS bucket '$BUCKET_NAME'? This will PERMANENTLY DELETE all data in the bucket. (y/N): " confirm_bucket_delete
set -x

if [[ "$confirm_bucket_delete" =~ ^[Yy]$ ]]; then
    log "Proceeding with bucket deletion..."
    if gsutil rm -r -f "gs://$BUCKET_NAME"; then
        log "GCS bucket '$BUCKET_NAME' deleted successfully"
    else
        log "ERROR: Failed to delete GCS bucket '$BUCKET_NAME'"
        exit 1
    fi
else
    log "Bucket deletion skipped by user"
fi

log "GCS Bucket teardown process completed successfully." 