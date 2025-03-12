#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common.sh"

# --- MAIN SCRIPT ---
init_script 'Docker Image Setup'

# Load environment variables
log "Loading environment variables..."
ENV_FILE="$PROJECT_DIR/source/.env"
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" || exit 1

# Set Docker directories and paths
DOCKER_DIR="$PROJECT_DIR/src/setup/docker"
DOCKER_COMPOSE_FILE="$DOCKER_DIR/docker-compose.yml"

# Define image name
TPU_IMAGE_NAME="eu.gcr.io/${PROJECT_ID}/tae-tpu:v1"

# Display configuration
log_section "Configuration"
log "Project ID: $PROJECT_ID"
log "Image name: $TPU_IMAGE_NAME"
log "Docker directory: $DOCKER_DIR"

# Set up authentication
setup_auth

# Configure Docker to use European Google Container Registry
log "Configuring Docker for eu.gcr.io..."
gcloud auth configure-docker eu.gcr.io --quiet

# Build the Docker image
log "Building Docker image..."
if [ -f "$DOCKER_COMPOSE_FILE" ]; then
    log "Using docker-compose to build image..."
    docker-compose -f "$DOCKER_COMPOSE_FILE" build
else
    log "docker-compose.yml not found, using direct build command..."
    docker build -t $TPU_IMAGE_NAME -f "$DOCKER_DIR/Dockerfile" "$DOCKER_DIR"
fi

# Check if build was successful
if [ $? -ne 0 ]; then
    log_error "Docker build failed"
    exit 1
fi

# Push the image to Google Container Registry
log "Pushing image to eu.gcr.io..."
docker push $TPU_IMAGE_NAME

# Verify push was successful
if [ $? -ne 0 ]; then
    log_error "Failed to push Docker image to GCR"
    exit 1
fi

log_success "Docker image build and push completed successfully"
log_success "Image available at: $TPU_IMAGE_NAME"
exit 0