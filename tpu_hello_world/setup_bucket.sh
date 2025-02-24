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
log 'Starting GCS bucket setup process...'

log 'Loading environment variables...'
source .env
log 'Environment variables loaded successfully'

log 'Setting up service account credentials...'
# Use absolute path
export GOOGLE_APPLICATION_CREDENTIALS="$(pwd)/$SERVICE_ACCOUNT_JSON"

if [ ! -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    log "ERROR: Service account credentials file not found at: $GOOGLE_APPLICATION_CREDENTIALS"
    exit 1
fi
log 'Service account credentials file found'

log 'Configuring Google Cloud project...'
gcloud config set project "$PROJECT_ID"
log "Project configured: $PROJECT_ID"

log 'Authenticating with service account...'
gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
log 'Service account authentication successful'

# Check if bucket exists
if gsutil ls -b "gs://$BUCKET_NAME" &> /dev/null; then
    log "Bucket '$BUCKET_NAME' already exists. Exiting."
    exit 1
fi

# Extract region from zone (remove the last character)
TPU_REGION=${ZONE%-*}
log "Using region $TPU_REGION for bucket location to match TPU location"

log "Creating GCS bucket: $BUCKET_NAME..."
gsutil mb -p "$PROJECT_ID" -l "$TPU_REGION" "gs://$BUCKET_NAME"

log "GCS bucket creation completed in region $TPU_REGION"
log "GCS Bucket Setup Complete. Bucket '$BUCKET_NAME' is ready." 