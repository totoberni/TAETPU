#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/infrastructure/utils/common.sh"

# --- MAIN SCRIPT ---
init_script 'Docker Image Setup'

# Load environment variables
log "Loading environment variables..."
ENV_FILE="$PROJECT_DIR/config/.env"
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" "IMAGE_NAME" || exit 1

# Display configuration
log_section "Configuration"
display_config "PROJECT_ID" "IMAGE_NAME"
log "This image is designed for TPU computation with source code mounted in /app/mount"

# Set up authentication
setup_auth

# Ensure Docker is running
if ! docker info > /dev/null 2>&1; then
  log_error "Docker is not running. Please start Docker first."
  exit 1
fi

# Authenticate Docker for Google Container Registry
log_section "Authenticating with Google Cloud"
gcloud auth configure-docker --quiet

# Build the Docker image
log_section "Building Docker image"
docker build -t "$IMAGE_NAME:latest" -f infrastructure/docker/Dockerfile .

# Push the Docker image to GCR
log_section "Pushing Docker image to Google Container Registry"
docker push "$IMAGE_NAME:latest"

log_success "Docker image setup complete. Image is available at: $IMAGE_NAME:latest"
exit 0