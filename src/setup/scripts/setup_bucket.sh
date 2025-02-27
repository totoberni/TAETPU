#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

# --- MAIN SCRIPT ---
init_script 'GCS bucket setup'
ENV_FILE="$PROJECT_DIR/source/.env"
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" "BUCKET_NAME" "BUCKET_REGION" || exit 1

# Display configuration
display_config "PROJECT_ID" "BUCKET_NAME" "BUCKET_REGION"

# Set up authentication
setup_auth

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