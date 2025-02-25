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

# Validate required environment variables
if [[ -z "$BUCKET_NAME" ]]; then
  log "ERROR: Required environment variable BUCKET_NAME is missing"
  log "Ensure BUCKET_NAME is set in .env"
  exit 1
fi

log "Configuration:"
log "- Bucket Name: $BUCKET_NAME"

# Set up authentication if provided
if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$SERVICE_ACCOUNT_JSON" ]]; then
  log 'Setting up service account credentials...'
  export GOOGLE_APPLICATION_CREDENTIALS="$(pwd)/$SERVICE_ACCOUNT_JSON"
  gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
  log 'Service account authentication successful'
fi

# Check if bucket exists
log "Checking if bucket exists..."
if ! gcloud storage buckets describe "gs://$BUCKET_NAME" &> /dev/null; then
    log "Bucket 'gs://$BUCKET_NAME' does not exist. Nothing to delete."
    exit 0
fi
log "Bucket 'gs://$BUCKET_NAME' found"

# Show bucket contents before asking for confirmation
log "Listing bucket contents before deletion:"
gcloud storage ls -l "gs://$BUCKET_NAME" 2>/dev/null || echo "Bucket is empty"

# Prompt for user confirmation
read -p "This will PERMANENTLY DELETE bucket 'gs://$BUCKET_NAME' and ALL its contents. This action CANNOT be undone. Type 'yes' to confirm: " confirm

if [[ "$confirm" != "yes" ]]; then
    log "Deletion cancelled by user. Exiting."
    exit 0
fi

# Delete the bucket and all its contents
log "Proceeding with bucket deletion..."
gcloud storage rm --recursive "gs://$BUCKET_NAME"

log "GCS bucket 'gs://$BUCKET_NAME' and all its contents have been deleted successfully."
log "GCS Bucket teardown process completed."