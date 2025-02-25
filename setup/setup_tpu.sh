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
log 'Starting TPU setup process...'

log 'Loading environment variables...'
source ../source/.env
log 'Environment variables loaded successfully'

# Validate required environment variables
if [[ -z "$PROJECT_ID" || -z "$TPU_ZONE" || -z "$TPU_TYPE" || -z "$TPU_NAME" ]]; then
  log "ERROR: Required environment variables are missing"
  log "Ensure PROJECT_ID, TPU_ZONE, TPU_TYPE, and TPU_NAME are set in .env"
  exit 1
fi

log "Configuration:"
log "- Project ID: $PROJECT_ID"
log "- TPU Zone: $TPU_ZONE"
log "- TPU Type: $TPU_TYPE"
log "- TPU Name: $TPU_NAME"

# Set up authentication if provided
if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$SERVICE_ACCOUNT_JSON" ]]; then
  log 'Setting up service account credentials...'
  export GOOGLE_APPLICATION_CREDENTIALS="$(pwd)/../source/$SERVICE_ACCOUNT_JSON"
  gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
  log 'Service account authentication successful'
fi

log 'Configuring Google Cloud project and zone...'
gcloud config set project "$PROJECT_ID"
gcloud config set compute/zone "$TPU_ZONE"
log "Project and zone configured: $PROJECT_ID in $TPU_ZONE"

# Check if the TPU already exists
if gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" &> /dev/null; then
  log "TPU '$TPU_NAME' already exists. Skipping TPU creation."
else
  # Create the TPU VM with specified parameters
  log "Creating TPU VM with name: $TPU_NAME, type: $TPU_TYPE..."

  CREATE_CMD="gcloud compute tpus tpu-vm create \"$TPU_NAME\" \
    --zone=\"$TPU_ZONE\" \
    --project=\"$PROJECT_ID\" \
    --accelerator-type=\"$TPU_TYPE\" \
    --version=\"tpu-ubuntu2204-base\""

  # Add service account if specified
  if [[ -n "$SERVICE_ACCOUNT_EMAIL" ]]; then
    CREATE_CMD="$CREATE_CMD --service-account=\"$SERVICE_ACCOUNT_EMAIL\""
  fi

  # Execute the command
  eval "$CREATE_CMD"

  log 'TPU VM creation completed successfully'
fi

# --- Docker Setup ---
log "Pulling Docker image..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all \
    --command="docker pull gcr.io/$PROJECT_ID/tpu-hello-world:v1"

log "Docker image pulled successfully."

log "TPU Setup Complete."