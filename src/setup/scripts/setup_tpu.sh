#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common.sh"

# --- MAIN SCRIPT ---
init_script 'TPU VM Setup'

# Load environment variables
log "Loading environment variables..."
ENV_FILE="$PROJECT_DIR/source/.env"
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" "TPU_NAME" "TPU_TYPE" "TPU_ZONE" "RUNTIME_VERSION" "SERVICE_ACCOUNT_EMAIL" || exit 1

# Define Docker image name
TPU_IMAGE_NAME="eu.gcr.io/${PROJECT_ID}/tae-tpu:v1"

# Display configuration
log_section "Configuration"
display_config "PROJECT_ID" "TPU_NAME" "TPU_TYPE" "TPU_ZONE" "RUNTIME_VERSION"
log "Image to pull: $TPU_IMAGE_NAME"

# Set up authentication
setup_auth

# Set the project and zone
log "Setting project to $PROJECT_ID and zone to $TPU_ZONE..."
gcloud config set project $PROJECT_ID
gcloud config set compute/zone $TPU_ZONE

# Check if TPU already exists using list command
log "Checking if TPU '$TPU_NAME' exists..."
if gcloud compute tpus tpu-vm list --filter="name:$TPU_NAME" --format="value(name)" | grep -q "$TPU_NAME"; then
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

# Configure Docker on TPU VM
log "Configuring Docker on TPU VM..."
gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE \
  --command="gcloud auth configure-docker eu.gcr.io --quiet"

# Pull the Docker image on TPU VM
log "Pulling Docker image on TPU VM..."
gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE \
  --command="sudo docker pull $TPU_IMAGE_NAME"

# Check if pull was successful
if [ $? -ne 0 ]; then
    log_warning "Failed to pull Docker image on TPU VM. Check if the image exists in GCR."
fi

# Perform TPU health check
log_section "TPU Health Check"
gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" --format="json" > /tmp/tpu_status.json
TPU_STATUS=$(cat /tmp/tpu_status.json | jq -r '.state')

if [ "$TPU_STATUS" == "READY" ]; then
    log_success "TPU is in READY state and available for use"
else
    log_warning "TPU is in $TPU_STATUS state, may not be ready for immediate use"
fi

log_success "TPU VM setup completed successfully"
log_success "To SSH into your TPU VM, use: gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE"
exit 0