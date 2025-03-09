#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DOCKER_DIR="$PROJECT_DIR/src/setup/docker"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common.sh"

# --- MAIN SCRIPT ---
init_script 'Docker Image Setup'
ENV_FILE="$PROJECT_DIR/source/.env"

# Load environment variables
log "Loading environment variables..."
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" || exit 1

# Display configuration
display_config "PROJECT_ID"

# Set up authentication locally
setup_auth

# Configure Docker to use GCR
log "Configuring Docker authentication..."
gcloud auth configure-docker gcr.io --quiet
gcloud auth configure-docker eu.gcr.io --quiet

# Define Docker image path
IMAGE_NAME="gcr.io/${PROJECT_ID}/tae-tpu:v1"
EU_IMAGE_NAME="eu.gcr.io/${PROJECT_ID}/tae-tpu:v1"

# Check if Dockerfile exists
if [[ ! -f "$DOCKER_DIR/Dockerfile" ]]; then
    log_error "Dockerfile not found at $DOCKER_DIR/Dockerfile"
    exit 1
fi

# Build Docker image
log "Building Docker image..."
docker build -t "$IMAGE_NAME" -t "$EU_IMAGE_NAME" "$DOCKER_DIR"

# Push Docker image to GCR
log "Pushing Docker image to Container Registry..."
docker push "$IMAGE_NAME"
docker push "$EU_IMAGE_NAME"

# If TPU exists, pull the image there
if [[ -n "$TPU_NAME" && -n "$TPU_ZONE" ]]; then
    log "Checking if TPU '$TPU_NAME' exists..."
    if gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" &> /dev/null; then
        log "TPU VM exists. Pulling Docker image on TPU VM..."
        
        # Configure Docker on TPU VM
        vmssh "gcloud auth configure-docker gcr.io --quiet"
        vmssh "gcloud auth configure-docker eu.gcr.io --quiet"
        
        # Pull Docker image on TPU VM
        vmssh "sudo docker pull $EU_IMAGE_NAME"
        
        log_success "Docker image pulled on TPU VM"
    else
        log "TPU VM does not exist or is not accessible. Skipping TPU setup."
    fi
else
    log "TPU_NAME or TPU_ZONE not set. Skipping TPU setup."
fi

log_success "Docker image setup completed successfully"
log_success "Image name: $IMAGE_NAME and $EU_IMAGE_NAME"
exit 0