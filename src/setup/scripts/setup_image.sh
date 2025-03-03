#!/bin/bash

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source common logging functions
source "$PROJECT_DIR/src/utils/common_logging.sh"

# Default values
ENV_FILE="$PROJECT_DIR/source/.env"
TPU_ENV_FILE="$PROJECT_DIR/source/tpu.env"
DOCKER_DIR="$PROJECT_DIR/src/setup/docker"
DOCKERFILE="$DOCKER_DIR/Dockerfile"
DOCKER_COMPOSE="$DOCKER_DIR/docker-compose.yaml"
FORCE_REBUILD=false
PUSH_IMAGE=true
TMP_BUILD_DIR=""

# Initialize the script
init_script "Docker Image Setup"

# Cleanup function
function cleanup {
  if [[ -n "$TMP_BUILD_DIR" && -d "$TMP_BUILD_DIR" ]]; then
    log "Cleaning up temporary build directory..."
    rm -rf "$TMP_BUILD_DIR"
  fi
}

# Set trap for cleanup
trap cleanup EXIT

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
log "Loading environment variables..."
load_env_vars "$ENV_FILE" || exit 1

# Load TPU-specific environment variables if they exist
if [[ -f "$TPU_ENV_FILE" ]]; then
  log "Loading TPU-specific environment variables..."
  source "$TPU_ENV_FILE"
  log_success "TPU-specific environment variables loaded"
else
  log_warning "TPU-specific environment file not found: $TPU_ENV_FILE"
  log "Creating default TPU environment file..."
  
  # Create default TPU environment file
  cat > "$TPU_ENV_FILE" << EOF
# TPU-specific configuration
MODEL_NAME=tensorflow-tpu-model
MODEL_DIR=/app/model
TPU_NAME=local

# TPU environment variables
PJRT_DEVICE=TPU
NEXT_PLUGGABLE_DEVICE_USE_C_API=true
TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so
TF_ENABLE_ONEDNN_OPTS=0
DNNL_MAX_CPU_ISA=AVX2
TF_XLA_FLAGS=--tf_xla_enable_xla_devices --tf_xla_cpu_global_jit
TF_CPP_MIN_LOG_LEVEL=0
XRT_TPU_CONFIG="localservice;0;localhost:51011"
ALLOW_MULTIPLE_LIBTPU_LOAD=1
EOF
  log_success "Default TPU environment file created"
  source "$TPU_ENV_FILE"
fi

# Verify environment variables
"$PROJECT_DIR/src/utils/verify.sh" --env || exit 1

# Display configuration
display_config "PROJECT_ID" "TF_VERSION" "MODEL_NAME" "MODEL_DIR" "TPU_NAME"

# Set up authentication
setup_auth

# Set image name
IMAGE_NAME="gcr.io/${PROJECT_ID}/tensorflow-tpu"
IMAGE_TAG="v1"
FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"

log "Building TensorFlow TPU Docker image with CPU optimizations"
log "- Image Name: $FULL_IMAGE_NAME"
log "- TensorFlow Version: $TF_VERSION"
log "- CPU Optimizations: AVX2, AVX512F, AVX512_VNNI, AVX512_BF16, FMA"
log "- Model Name: $MODEL_NAME"
log "- Model Directory: $MODEL_DIR"

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

# Create temporary build directory
TMP_BUILD_DIR=$(mktemp -d)
log "Created temporary build directory: $TMP_BUILD_DIR"

# Copy Dockerfile, docker-compose.yaml, and requirements.txt to the build directory
cp "$DOCKERFILE" "$TMP_BUILD_DIR/"
cp "$DOCKER_DIR/requirements.txt" "$TMP_BUILD_DIR/"
cp "$DOCKER_DIR/entrypoint.sh" "$TMP_BUILD_DIR/" 2>/dev/null || log_warning "Entrypoint script not found, it will be created in the Dockerfile"
cp "$DOCKER_COMPOSE" "$TMP_BUILD_DIR/" 2>/dev/null || log_warning "Docker Compose file not found, will not be copied"

# Change to the temporary build directory
cd "$TMP_BUILD_DIR"

# Build Docker image locally
log "Building Docker image locally with CPU optimizations..."
if docker build -t "$FULL_IMAGE_NAME" .; then
  log_success "Docker image built successfully"
else
  log_error "Failed to build Docker image locally"
  exit 1
fi

# Push Docker image to GCR
if [[ "$PUSH_IMAGE" == "true" ]]; then
  log "Pushing Docker image to GCR..."
  if docker push "$FULL_IMAGE_NAME"; then
    log_success "Docker image pushed to GCR successfully"
  else
    log_error "Failed to push Docker image to GCR"
    log "Check your authentication credentials and try again"
    exit 1
  fi
fi

# Copy docker-compose.yaml to the project directory if it doesn't exist
if [[ ! -f "$DOCKER_COMPOSE" && -f "$TMP_BUILD_DIR/docker-compose.yaml" ]]; then
  log "Copying docker-compose.yaml to project directory..."
  cp "$TMP_BUILD_DIR/docker-compose.yaml" "$DOCKER_COMPOSE"
  log_success "Docker Compose file copied to project directory"
fi

log_success "TensorFlow TPU Docker image setup complete: $FULL_IMAGE_NAME"
log "To create a TPU VM and deploy the image, run:"
log "$PROJECT_DIR/src/setup/scripts/setup_tpu.sh"
log "Then, to verify image functionality, run:"
log "$PROJECT_DIR/src/utils/verify.sh --image"

exit 0