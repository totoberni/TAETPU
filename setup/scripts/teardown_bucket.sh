#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$SCRIPT_DIR/common.sh"

# --- MAIN SCRIPT ---
log 'Starting GCS bucket teardown process...'

log 'Loading environment variables...'
# Load from the absolute path
ENV_FILE="$PROJECT_DIR/source/.env"
source "$ENV_FILE"
log_success 'Environment variables loaded successfully'

# Validate required environment variables
if [[ -z "$BUCKET_NAME" ]]; then
  log_error "Required environment variable BUCKET_NAME is missing"
  log_error "Ensure BUCKET_NAME is set in .env"
  exit 1
fi

log "Configuration:"
log "- Bucket Name: $BUCKET_NAME"

# Set up authentication if provided
if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON" ]]; then
  log 'Setting up service account credentials...'
  export GOOGLE_APPLICATION_CREDENTIALS="$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON"
  gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
  log_success 'Service account authentication successful'
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