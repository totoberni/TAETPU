#!/bin/bash

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source common logging functions
source "$PROJECT_DIR/src/utils/common_logging.sh"

# Default values
ENV_FILE="$PROJECT_DIR/source/.env"
DOCKER_DIR="$PROJECT_DIR/src/setup/docker"
DOCKERFILE="$DOCKER_DIR/Dockerfile"
FORCE_REBUILD=false
PUSH_IMAGE=true

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --no-push)
      PUSH_IMAGE=false
      shift
      ;;
    --force-rebuild)
      FORCE_REBUILD=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Build Docker image for TPU development"
      echo ""
      echo "Options:"
      echo "  --no-push          Don't push the image to GCR"
      echo "  --force-rebuild    Force rebuild even if image exists"
      echo "  -h, --help         Show this help message"
      exit 1
      ;;
    *)
      log_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Load environment variables
load_env_vars "$ENV_FILE" || exit 1

# Verify environment variables
"$PROJECT_DIR/src/utils/verify.sh" --env || exit 1

# Set up authentication
setup_auth

# Set image name
IMAGE_NAME="gcr.io/${PROJECT_ID}/tpu-hello-world"
IMAGE_TAG="v1"
FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"

# Check if image already exists
if [[ "$FORCE_REBUILD" == "false" ]]; then
  log "Checking if image already exists in GCR..."
  if gcloud container images describe "$FULL_IMAGE_NAME" &>/dev/null; then
    log_success "Image $FULL_IMAGE_NAME already exists in GCR"
    read -p "Do you want to rebuild anyway? (y/n): " rebuild
    if [[ "$rebuild" != "y" && "$rebuild" != "Y" ]]; then
      log "Skipping image build. Using existing image: $FULL_IMAGE_NAME"
      exit 0
    fi
  fi
fi

# Check if Dockerfile exists
if [[ ! -f "$DOCKERFILE" ]]; then
  log_error "Dockerfile not found at $DOCKERFILE"
  log "Please create a Dockerfile before running this script"
  exit 1
fi

log "Using existing Dockerfile at $DOCKERFILE"

# Build Docker image
log "Building Docker image: $FULL_IMAGE_NAME"
if docker build -t "$FULL_IMAGE_NAME" -f "$DOCKERFILE" "$DOCKER_DIR"; then
  log_success "Docker image built successfully"
else
  log_error "Failed to build Docker image"
  exit 1
fi

# Push Docker image to GCR
if [[ "$PUSH_IMAGE" == "true" ]]; then
  log "Pushing Docker image to GCR..."
  if docker push "$FULL_IMAGE_NAME"; then
    log_success "Docker image pushed to GCR successfully"
  else
    log_error "Failed to push Docker image to GCR"
    exit 1
  fi
fi

log_success "Docker image setup complete: $FULL_IMAGE_NAME"
log "To use this image on your TPU VM:"
echo "docker run --rm --privileged \\
  --device=/dev/accel0 \\
  -e PJRT_DEVICE=TPU \\
  -e XLA_USE_BF16=1 \\
  -e TPU_NAME=local \\
  -v /lib/libtpu.so:/lib/libtpu.so \\
  -v /path/to/your/code:/app/code \\
  $FULL_IMAGE_NAME \\
  python /app/code/your_script.py"

log ""
log "To verify image functionality, run:"
log "$PROJECT_DIR/src/utils/verify.sh --image"

exit 0