#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

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

# Configure Docker authentication directly on the TPU VM
log "Configuring Docker authentication on TPU VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="gcloud auth configure-docker gcr.io --quiet"
log_success "Docker authentication configured"

# Pull Docker image on TPU VM
log "Pulling Docker image on TPU VM..."
IMAGE_NAME="gcr.io/${PROJECT_ID}/tpu-hello-world:v1"
PULL_CMD="docker pull ${IMAGE_NAME}"

gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="${PULL_CMD}"
log_success "Docker image pulled successfully on TPU VM"

# Prepare Docker run command
RUN_CMD="docker run --privileged --rm \
  -v /dev:/dev \
  -v /lib/libtpu.so:/lib/libtpu.so \
  -p 5000:5000 \
  -p 6006:6006 \
  ${IMAGE_NAME}"

log_success "Setup completed successfully!"
log_success "Use 'gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE' to connect to your TPU VM"
log_success "Run the container with this command:"
log_success "${RUN_CMD}"