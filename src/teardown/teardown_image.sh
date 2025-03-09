#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common.sh"

# --- MAIN SCRIPT ---
init_script 'Docker Image Teardown'
ENV_FILE="$PROJECT_DIR/source/.env"

# Load environment variables
log "Loading environment variables..."
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" || exit 1

# Set up authentication locally
setup_auth

# Define Docker image path
IMAGE_NAME="gcr.io/${PROJECT_ID}/tae-tpu:v1"
EU_IMAGE_NAME="eu.gcr.io/${PROJECT_ID}/tae-tpu:v1"

# Check if TPU exists and clean up there first
if [[ -n "$TPU_NAME" && -n "$TPU_ZONE" ]]; then
    log "Checking if TPU '$TPU_NAME' exists..."
    if gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" &> /dev/null; then
        log "TPU VM exists. Cleaning up Docker images on TPU VM..."
        
        # Remove Docker image from TPU VM
        vmssh "docker rmi $IMAGE_NAME $EU_IMAGE_NAME || true"
        
        log_success "Cleaned up Docker images on TPU VM"
    else
        log "TPU VM does not exist or is not accessible. Skipping TPU cleanup."
    fi
else
    log "TPU_NAME or TPU_ZONE not set. Skipping TPU cleanup."
fi

# Check if the image exists in GCR
log "Checking if Docker image exists in Container Registry..."

# Check for the image in GCR
GCR_CHECK=$(gcloud container images list --repository=gcr.io/${PROJECT_ID} --format="value(name)" | grep -c "tae-tpu" || true)
EU_GCR_CHECK=$(gcloud container images list --repository=eu.gcr.io/${PROJECT_ID} --format="value(name)" | grep -c "tae-tpu" || true)

if [[ "$GCR_CHECK" -eq 0 && "$EU_GCR_CHECK" -eq 0 ]]; then
    log_warning "Docker image not found in Container Registry. Nothing to delete."
    exit 0
fi

# Confirm deletion
read -p "Are you sure you want to delete the Docker image(s)? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
    log "Deletion cancelled."
    exit 0
fi

# Delete the Docker image from GCR
if [[ "$GCR_CHECK" -gt 0 ]]; then
    log "Deleting Docker image from gcr.io..."
    gcloud container images delete "$IMAGE_NAME" --quiet
    log_success "Docker image deleted from gcr.io"
fi

if [[ "$EU_GCR_CHECK" -gt 0 ]]; then
    log "Deleting Docker image from eu.gcr.io..."
    gcloud container images delete "$EU_IMAGE_NAME" --quiet
    log_success "Docker image deleted from eu.gcr.io"
fi

# Clean up local Docker images
log "Cleaning up local Docker images..."
docker rmi "$IMAGE_NAME" "$EU_IMAGE_NAME" 2>/dev/null || true

log_success "Docker image teardown completed successfully"
exit 0 