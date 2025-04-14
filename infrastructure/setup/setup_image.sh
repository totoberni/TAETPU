#!/bin/bash

# Get script directory for absolute path references
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Import common functions
source "$PROJECT_DIR/infrastructure/utils/common.sh"

# Initialize
init_script 'Docker Image Setup'

# Load environment variables
log "Loading environment variables..."
ENV_FILE="$PROJECT_DIR/config/.env"
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" "BUCKET_NAME" "SERVICE_ACCOUNT_JSON" || exit 1

# Set Docker directories
DOCKER_DIR="$PROJECT_DIR/infrastructure/docker"
DOCKER_COMPOSE_FILE="$DOCKER_DIR/docker-compose.yml"

# Set image name
TPU_IMAGE_NAME="eu.gcr.io/${PROJECT_ID}/tae-tpu:v1"
log_success "Image reference: $TPU_IMAGE_NAME"

# Display configuration
log_section "Configuration"
log "Project ID: $PROJECT_ID"
log "Image name: $TPU_IMAGE_NAME"

# Set up authentication
setup_auth

# Configure Docker for GCR
log "Configuring Docker for GCR..."
gcloud auth configure-docker eu.gcr.io --quiet

# Clean up existing container/image if it exists
log "Cleaning up existing container/image..."
CONTAINER_NAME="tae-tpu-container"
docker rm -f $CONTAINER_NAME 2>/dev/null || true
docker rmi $TPU_IMAGE_NAME 2>/dev/null || true

# Build and push Docker image
log "Building and pushing Docker image..."

# Change directory to project root (for build context)
pushd "$PROJECT_DIR" > /dev/null

# Export required environment variables for docker-compose
export PROJECT_ID
export SERVICE_ACCOUNT_JSON

# Build using docker-compose
log "Building with docker-compose..."
docker-compose -f "$DOCKER_COMPOSE_FILE" build

# Check build status
if [ $? -ne 0 ]; then
    log_error "Docker build failed"
    popd > /dev/null
    exit 1
fi

# Push the image
log "Pushing image to GCR..."
docker push $TPU_IMAGE_NAME

# Check push status
if [ $? -ne 0 ]; then
    log_error "Failed to push Docker image to GCR"
    popd > /dev/null
    exit 1
fi

popd > /dev/null

log_success "Docker image build and push completed successfully"
log_success "Image available at: $TPU_IMAGE_NAME"
exit 0