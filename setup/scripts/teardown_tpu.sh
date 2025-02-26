#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$SCRIPT_DIR/common.sh"

# --- MAIN SCRIPT ---
init_script 'TPU teardown'
ENV_FILE="$PROJECT_DIR/source/.env"
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_NAME" || exit 1

# Display configuration
display_config "PROJECT_ID" "TPU_ZONE" "TPU_NAME"

# Set up authentication
setup_auth

# Check if TPU exists
log "Checking if TPU '$TPU_NAME' exists..."
if ! gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" &> /dev/null; then
  log "TPU '$TPU_NAME' does not exist. Nothing to delete."
  exit 0
fi

log "TPU '$TPU_NAME' found. Proceeding with deletion..."

# Delete the TPU VM
log "Deleting TPU VM '$TPU_NAME'..."
gcloud compute tpus tpu-vm delete "$TPU_NAME" \
  --project="$PROJECT_ID" \
  --zone="$TPU_ZONE" \
  --quiet

log "TPU '$TPU_NAME' deletion completed successfully."
log "TPU teardown process completed."