#!/bin/bash
# Docker Image Setup Script - Builds and pushes Docker image to Google Container Registry
set -e

# ---- Script Constants and Imports ----
# Get the project directory (2 levels up from this script)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/../.." &> /dev/null && pwd )"
ENV_FILE="$PROJECT_DIR/config/.env"

# Import common utilities
source "$SCRIPT_DIR/../utils/common.sh"

# ---- Functions ----

# Validate environment variables and dependencies
function validate_environment() {
  log "Validating environment..."
  
  # Required environment variables
  check_env_vars "PROJECT_ID" "IMAGE_NAME" || exit 1
  load_env_vars "$ENV_FILE"
  
  # Set default tag if not defined
  CONTAINER_TAG="${CONTAINER_TAG:-latest}"
  
  # Display configuration
  log_section "Configuration"
  display_config "PROJECT_ID" "IMAGE_NAME" "CONTAINER_TAG"
  log "This image is designed for TPU computation with source code mounted in /app/mount"
  
  # Set up authentication
  setup_auth
  
  # Ensure Docker is running
  if ! docker info > /dev/null 2>&1; then
    log_error "Docker is not running. Please start Docker first."
    exit 1
  fi
}

# Configure Docker authentication for GCR
function configure_docker_auth() {
  log_section "Authenticating with Google Cloud"
  gcloud auth configure-docker --quiet
}

# Parse TPU environment variables
function parse_tpu_env_vars() {
  log_section "Parsing TPU environment variables"
  
  # Parse TPU optimization variables from .env
  TPU_ENV_FLAGS="-e PJRT_DEVICE=TPU"
  [ -n "${XRT_TPU_CONFIG}" ] && TPU_ENV_FLAGS+=" -e XRT_TPU_CONFIG=\"${XRT_TPU_CONFIG}\""
  [ -n "${XLA_USE_BF16}" ] && TPU_ENV_FLAGS+=" -e XLA_USE_BF16=${XLA_USE_BF16}"
  [ -n "${XLA_TENSOR_ALLOCATOR_MAXSIZE}" ] && TPU_ENV_FLAGS+=" -e XLA_TENSOR_ALLOCATOR_MAXSIZE=${XLA_TENSOR_ALLOCATOR_MAXSIZE}"
  [ -n "${TPU_NUM_DEVICES}" ] && TPU_ENV_FLAGS+=" -e TPU_NUM_DEVICES=${TPU_NUM_DEVICES}"
  [ -n "${XLA_FLAGS}" ] && TPU_ENV_FLAGS+=" -e XLA_FLAGS=\"${XLA_FLAGS}\""
  
  log "TPU environment flags: ${TPU_ENV_FLAGS}"
}

# Build and push Docker image
function build_and_push_image() {
  # Parse TPU environment variables
  parse_tpu_env_vars
  
  # Build the Docker image
  log_section "Building Docker image"
  log "Building image: $IMAGE_NAME:$CONTAINER_TAG"
  docker build -t "$IMAGE_NAME:$CONTAINER_TAG" -f "$PROJECT_DIR/infrastructure/docker/Dockerfile" "$PROJECT_DIR"
  
  # Push the Docker image to GCR
  log_section "Pushing Docker image to Google Container Registry"
  log "Pushing image: $IMAGE_NAME:$CONTAINER_TAG"
  docker push "$IMAGE_NAME:$CONTAINER_TAG"
}

# Main function
function main() {
  # Initialize
  init_script 'Docker Image Setup'
  
  # Load environment variables
  load_env_vars "$ENV_FILE"
  
  # Validate environment
  validate_environment
  
  # Configure Docker authentication
  configure_docker_auth
  
  # Build and push image
  build_and_push_image
  
  # Completed
  log_success "Docker image setup complete. Image is available at: $IMAGE_NAME:$CONTAINER_TAG"
}

# ---- Main Execution ----
main