#!/bin/bash

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source common logging functions
source "$PROJECT_DIR/src/utils/common_logging.sh"

# Default values
ENV_FILE="$PROJECT_DIR/source/.env"
DOCKER_DIR="$PROJECT_DIR/src/setup/docker"
DOCKERFILE="$DOCKER_DIR/Dockerfile"
FORCE_REBUILD=false
PUSH_IMAGE=true

# Initialize the script
init_script "Docker Image Setup"

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

# Display configuration
display_config "PROJECT_ID" "TPU_NAME" "TPU_ZONE"

# Set up authentication
setup_auth

# Set image name
IMAGE_NAME="gcr.io/${PROJECT_ID}/tpu-hello-world"
IMAGE_TAG="v1"
FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"

log "Note: Your TPU VM already uses a pre-built image with TensorFlow configured for TPU usage."
log "Additional dependencies are installed directly on the TPU VM during setup."
read -p "Do you want to build a custom Docker image? This is optional. (y/n): " continue_build

if [[ "$continue_build" != "y" && "$continue_build" != "Y" ]]; then
  log "Skipping Docker image build. Using the pre-built image directly."
  exit 0
fi

# Check if Dockerfile exists
if [[ ! -f "$DOCKERFILE" ]]; then
  log_error "Dockerfile not found at $DOCKERFILE"
  exit 1
fi

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

# First verify TPU VM exists and is accessible
if ! verify_tpu_existence "$TPU_NAME" "$TPU_ZONE" "$PROJECT_ID"; then
  log_error "TPU VM not found. Please run setup_tpu.sh first."
  exit 1
fi

# Copy Dockerfile and requirements.txt to TPU VM
log "Copying Dockerfile and requirements.txt to TPU VM..."
gcloud compute tpus tpu-vm scp "$DOCKERFILE" "$TPU_NAME":/tmp/Dockerfile \
  --zone="$TPU_ZONE" \
  --project="$PROJECT_ID" || {
    log_error "Failed to copy Dockerfile to TPU VM"
    exit 1
  }

gcloud compute tpus tpu-vm scp "$DOCKER_DIR/requirements.txt" "$TPU_NAME":/tmp/requirements.txt \
  --zone="$TPU_ZONE" \
  --project="$PROJECT_ID" || {
    log_error "Failed to copy requirements.txt to TPU VM"
    exit 1
  }

# Build Docker image on TPU VM
log "Building Docker image on TPU VM..."
ssh_with_timeout "cd /tmp && docker build -t $FULL_IMAGE_NAME -f Dockerfile ." 300 || {
  log_error "Failed to build Docker image on TPU VM (timeout or error)"
  exit 1
}

# Push Docker image to GCR
if [[ "$PUSH_IMAGE" == "true" ]]; then
  log "Pushing Docker image to GCR..."
  ssh_with_timeout "docker push $FULL_IMAGE_NAME" 300 || {
    log_error "Failed to push Docker image to GCR (timeout or error)"
    exit 1
  }
fi

log_success "Docker image setup complete: $FULL_IMAGE_NAME"
log "To verify image functionality, run:"
log "$PROJECT_DIR/src/utils/verify.sh --image"

exit 0