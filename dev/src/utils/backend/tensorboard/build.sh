# src/backend/tensorboard/build.sh
#!/bin/bash

# Get script directory for absolute path references
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Import common functions
source "$PROJECT_DIR/src/utils/common_logging.sh"

# Main script
init_script 'TensorBoard backend image build'
ENV_FILE="$PROJECT_DIR/source/.env"
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" || exit 1

# Display configuration
display_config "PROJECT_ID"
log "- Image Name: tensorboard-backend"
log "- Image Tag: v1"

# Set up authentication
setup_auth

# Build Docker image
log "Building TensorBoard backend Docker image..."
CURRENT_DIR=$(pwd)
cd "$PROJECT_DIR"

if docker build -t tensorboard-backend:v1 -f src/backend/tensorboard/Dockerfile .; then
  log_success "Docker image built successfully"
else
  log_error "Failed to build Docker image"
  cd "$CURRENT_DIR"
  exit 1
fi

# Tag Docker image
log "Tagging Docker image for GCR..."
if docker tag tensorboard-backend:v1 gcr.io/${PROJECT_ID}/tensorboard-backend:v1; then
  log "Image tagged successfully"
else
  log_error "Failed to tag Docker image"
  exit 1
fi

# Push Docker image to GCR
log "Pushing Docker image to Google Container Registry..."
if docker push gcr.io/${PROJECT_ID}/tensorboard-backend:v1; then
  log_success "Docker image pushed successfully to gcr.io/${PROJECT_ID}/tensorboard-backend:v1"
else
  log_error "Failed to push Docker image to GCR"
  exit 1
fi

cd "$CURRENT_DIR"
log "TensorBoard backend image build complete."