#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common.sh"

# --- MAIN SCRIPT ---
init_script 'TPU VM setup'
ENV_FILE="$PROJECT_DIR/source/.env"

# Load environment variables
log "Loading environment variables..."
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" "TPU_NAME" "TPU_TYPE" "TPU_ZONE" "RUNTIME_VERSION" "SERVICE_ACCOUNT_EMAIL" || exit 1

# Display configuration
display_config "PROJECT_ID" "TPU_NAME" "TPU_TYPE" "TPU_ZONE" "RUNTIME_VERSION"

# Set up authentication locally
setup_auth

# Set the project and zone
log "Setting project to $PROJECT_ID and zone to $TPU_ZONE..."
gcloud config set project $PROJECT_ID
gcloud config set compute/zone $TPU_ZONE

# Check if TPU already exists
log "Checking if TPU '$TPU_NAME' exists..."
if gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" &> /dev/null; then
    log_warning "TPU '$TPU_NAME' already exists. Skipping creation."
else
    # Create the TPU VM with appropriate parameters
    log "Creating TPU VM '$TPU_NAME'..."
    gcloud compute tpus tpu-vm create "$TPU_NAME" \
        --zone="$TPU_ZONE" \
        --accelerator-type="$TPU_TYPE" \
        --version="$RUNTIME_VERSION" \
        --network="default" \
        --service-account="$SERVICE_ACCOUNT_EMAIL" \
        --scopes="https://www.googleapis.com/auth/cloud-platform" \
        --metadata="install-nvidia-driver=True"
    
    log_success "TPU VM created successfully"
fi

log_success "TPU VM setup completed successfully!"
log_success "To SSH into your TPU VM, use: gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE"

# Add health check
log "Performing TPU health check..."
gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" --format="json" > /tmp/tpu_status.json
TPU_STATUS=$(cat /tmp/tpu_status.json | jq -r '.state')

if [ "$TPU_STATUS" == "READY" ]; then
    log_success "TPU is in READY state and available for use"
else
    log_warning "TPU is in $TPU_STATUS state, may not be ready for immediate use"
fi