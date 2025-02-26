#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$SCRIPT_DIR/common.sh"

# --- MAIN SCRIPT ---
log 'Starting GCS bucket setup process...'

log 'Loading environment variables...'
# Load from the absolute path
ENV_FILE="$PROJECT_DIR/source/.env"
source "$ENV_FILE"
log_success 'Environment variables loaded successfully'

# Validate required environment variables
if [[ -z "$PROJECT_ID" || -z "$BUCKET_NAME" || -z "$BUCKET_REGION" ]]; then
  log_error "Required environment variables are missing"
  log_error "Ensure PROJECT_ID, BUCKET_NAME, and BUCKET_REGION are set in .env"
  exit 1
fi

log "Configuration:"
log "- Project ID: $PROJECT_ID"
log "- Bucket Name: $BUCKET_NAME"
log "- Region: $BUCKET_REGION"

# Set up authentication if provided
if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON" ]]; then
  log 'Setting up service account credentials...'
  export GOOGLE_APPLICATION_CREDENTIALS="$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON"
  gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
  log_success 'Service account authentication successful'
fi

# Check if bucket exists
if gcloud storage buckets describe "gs://$BUCKET_NAME" &> /dev/null; then
    log "Bucket 'gs://$BUCKET_NAME' already exists. Exiting."
    exit 0
fi

# Create the bucket with specified settings
log "Creating GCS bucket: gs://$BUCKET_NAME..."
gcloud storage buckets create "gs://$BUCKET_NAME" \
    --location="$BUCKET_REGION" \
    --default-storage-class="STANDARD" \
    --uniform-bucket-level-access

log "GCS bucket creation completed in region $BUCKET_REGION"
log "GCS Bucket Setup Complete. Bucket 'gs://$BUCKET_NAME' is ready."