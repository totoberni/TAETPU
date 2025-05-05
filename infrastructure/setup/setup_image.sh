#!/bin/bash
set -e

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
check_env_vars "PROJECT_ID" "SERVICE_ACCOUNT_JSON" || exit 1

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
log "This image is designed for TPU computation with source code mounted in /src"

# Set up authentication
setup_auth

# Ensure Docker is running
if ! docker info > /dev/null 2>&1; then
  log_error "Docker is not running. Please start Docker first."
  exit 1
fi

# Authenticate Docker for Google Container Registry
log_info "Authenticating with Google Cloud"
gcloud auth configure-docker --quiet

# Build the Docker image with proper tagging
log_info "Building Docker image"
docker build -t gcr.io/${PROJECT_ID}/taetpu:latest \
  -t gcr.io/${PROJECT_ID}/taetpu:v1 \
  -f infrastructure/docker/Dockerfile .

# Push the Docker image to GCR
log_info "Pushing Docker image to Google Container Registry"
docker push gcr.io/${PROJECT_ID}/taetpu:latest
docker push gcr.io/${PROJECT_ID}/taetpu:v1

log_info "Docker image setup complete. Image is available at: gcr.io/${PROJECT_ID}/taetpu:latest"
exit 0