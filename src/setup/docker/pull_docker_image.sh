#!/bin/bash

# Get script directory for absolute path references
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Import common logging
source "$PROJECT_DIR/src/utils/common_logging.sh"

# Main functionality
PROJECT_ID=$(gcloud config get-value project)
IMAGE_NAME="gcr.io/${PROJECT_ID}/tpu-hello-world:v1"

log "Attempting to pull Docker image: ${IMAGE_NAME}"

# Try regular pull
if docker pull ${IMAGE_NAME}; then
    log_success "Successfully pulled Docker image"
    exit 0
fi

log "Pull failed. Trying with re-authentication..."

# Try re-authenticating and then pulling
gcloud auth configure-docker --quiet
if docker pull ${IMAGE_NAME}; then
    log_success "Successfully pulled Docker image after re-authentication"
    exit 0
fi

log_error "All attempts to pull the Docker image failed"
log_error "Please ensure:"
log_error "1. The image exists at: ${IMAGE_NAME}"
log_error "2. Service account has necessary permissions"
log_error "3. Project ID is correct: ${PROJECT_ID}"
exit 1 