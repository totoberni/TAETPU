#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common.sh"

# --- MAIN SCRIPT ---
init_script 'TPU VM Teardown'
ENV_FILE="$PROJECT_DIR/source/.env"

# Load environment variables
log "Loading environment variables..."
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" "TPU_NAME" "TPU_ZONE" || exit 1

# Display configuration
display_config "PROJECT_ID" "TPU_NAME" "TPU_ZONE"

# Set up authentication locally
setup_auth

# Check if TPU exists
log "Checking if TPU '$TPU_NAME' exists..."
if ! gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" &> /dev/null; then
    log_warning "TPU '$TPU_NAME' does not exist. Nothing to delete."
    exit 0
fi

# Confirm deletion
read -p "Are you sure you want to delete TPU '$TPU_NAME'? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
    log "Deletion cancelled."
    exit 0
fi

# Delete the TPU VM
log "Deleting TPU VM '$TPU_NAME'..."
gcloud compute tpus tpu-vm delete "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --quiet

log_success "TPU VM deleted successfully"
exit 0