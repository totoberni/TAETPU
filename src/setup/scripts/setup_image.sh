#!/bin/bash
# This script builds (and optionally pushes) the Docker image for TPU development.

# --- Determine directories ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/../../.." && pwd )"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

# --- Script variables ---
ENV_FILE="$PROJECT_DIR/source/.env"
DOCKERFILE="$PROJECT_DIR/src/setup/docker/Dockerfile"
BAKE_TPU_DRIVER=false
FORCE_REBUILD=false
PUSH_IMAGE=true
CUSTOM_DOCKERFILE=""

# --- Display usage ---
function show_usage() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Build Docker image for TPU development"
  echo ""
  echo "Options:"
  echo "  --bake-driver      Bake the TPU driver (libtpu.so) into the image"
  echo "  --no-push          Don't push the image to GCR"
  echo "  --force-rebuild    Force rebuild even if image exists"
  echo "  --dockerfile=<path> Use a custom Dockerfile"
  echo "  -h, --help         Show this help message"
  exit 1
}

# --- Parse command line arguments ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --bake-driver)
      BAKE_TPU_DRIVER=true
      shift ;;
    --no-push)
      PUSH_IMAGE=false
      shift ;;
    --force-rebuild)
      FORCE_REBUILD=true
      shift ;;
    --dockerfile=*)
      CUSTOM_DOCKERFILE="${1#*=}"
      shift ;;
    -h|--help)
      show_usage ;;
    *)
      log_error "Unknown option: $1"
      show_usage ;;
  esac
done

init_script "TPU Docker Image Builder"

# --- Verify and load environment variables ---
log "Verifying environment variables..."
"$PROJECT_DIR/src/utils/verify.sh" --env-only || {
  log_error "Environment verification failed. Please fix the issues before proceeding."
  exit 1
}

log "Loading environment variables from $ENV_FILE..."
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
  log_success "Environment variables loaded"
else
  log_error "No .env file found at $ENV_FILE"
  exit 1
fi

check_env_vars "PROJECT_ID" "TF_VERSION" "TPU_VM_VERSION" || exit 1
setup_auth

IMAGE_NAME="gcr.io/${PROJECT_ID}/tpu-hello-world"
IMAGE_TAG="v1"
FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"

if [[ "$FORCE_REBUILD" == "false" ]]; then
  log "Checking if image already exists in GCR..."
  if gcloud container images describe "$FULL_IMAGE_NAME" &>/dev/null; then
    log_success "Image $FULL_IMAGE_NAME already exists in GCR"
    read -p "Rebuild anyway? (y/n): " rebuild
    if [[ "$rebuild" != "y" && "$rebuild" != "Y" ]]; then
      log "Skipping image build. Using existing image: $FULL_IMAGE_NAME"
      exit 0
    fi
  fi
fi

log "Building Docker image: $FULL_IMAGE_NAME"
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

# Copy requirements file and entrypoint script into build directory
cp "$PROJECT_DIR/src/setup/docker/requirements.txt" "$BUILD_DIR/"
cp "$PROJECT_DIR/src/setup/docker/entrypoint.sh" "$BUILD_DIR/"

if [[ "$BAKE_TPU_DRIVER" == "true" ]]; then
  log "Baking TPU driver into image..."
  source "$PROJECT_DIR/src/utils/verify.sh"
  TPU_DRIVER_PATH=$(check_tpu_driver "$TPU_NAME" "$TPU_ZONE" "$PROJECT_ID")
  if [[ $? -ne 0 || -z "$TPU_DRIVER_PATH" ]]; then
    log_error "Could not find TPU driver (libtpu.so) on TPU VM"
    exit 1
  fi
  log_success "Found TPU driver at: $TPU_DRIVER_PATH"
  
  log "Copying TPU driver from TPU VM..."
  gcloud compute tpus tpu-vm scp "$TPU_NAME":"$TPU_DRIVER_PATH" "$BUILD_DIR/libtpu.so" \
    --zone="$TPU_ZONE" --project="$PROJECT_ID"
  
  cat > "$BUILD_DIR/Dockerfile" <<EOF
FROM tensorflow/tensorflow:${TF_VERSION}

WORKDIR /app

# Install requirements
COPY requirements.txt /tmp/
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# Copy the baked TPU driver
COPY libtpu.so \${TF_PLUGGABLE_DEVICE_LIBRARY_PATH}

# Set TPU environment variables
ENV PJRT_DEVICE=TPU
ENV NEXT_PLUGGABLE_DEVICE_USE_C_API=true
ENV TF_PLUGGABLE_DEVICE_LIBRARY_PATH=\${TF_PLUGGABLE_DEVICE_LIBRARY_PATH}
ENV TPU_NAME=local
ENV TPU_LOAD_LIBRARY=0
ENV XLA_USE_BF16=1
ENV PYTHONUNBUFFERED=1

# Copy entrypoint script
COPY entrypoint.sh /app/
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["/bin/bash"]
EOF
  log_success "Created Dockerfile with baked TPU driver"
else
  if [[ -n "$CUSTOM_DOCKERFILE" && -f "$CUSTOM_DOCKERFILE" ]]; then
    log "Using custom Dockerfile: $CUSTOM_DOCKERFILE"
    cp "$CUSTOM_DOCKERFILE" "$BUILD_DIR/Dockerfile"
  else
    log "Using standard Dockerfile (TPU driver will be mounted at runtime)"
    cat > "$BUILD_DIR/Dockerfile" <<EOF
FROM tensorflow/tensorflow:${TF_VERSION}

WORKDIR /app

# Install requirements
COPY requirements.txt /tmp/
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# Set TPU environment variables
ENV PJRT_DEVICE=TPU
ENV NEXT_PLUGGABLE_DEVICE_USE_C_API=true
ENV TF_PLUGGABLE_DEVICE_LIBRARY_PATH=\${TF_PLUGGABLE_DEVICE_LIBRARY_PATH}
ENV TPU_NAME=local
ENV TPU_LOAD_LIBRARY=0
ENV XLA_USE_BF16=1
ENV PYTHONUNBUFFERED=1

# Copy entrypoint script
COPY entrypoint.sh /app/
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["/bin/bash"]
EOF
  fi
  log_success "Created standard Dockerfile"
fi

log "Building Docker image..."
if docker build -t "$FULL_IMAGE_NAME" "$BUILD_DIR"; then
  log_success "Docker image built successfully"
else
  log_error "Failed to build Docker image"
  exit 1
fi

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
if [[ "$BAKE_TPU_DRIVER" == "true" ]]; then
  log "Image includes baked-in TPU driver at \${TF_PLUGGABLE_DEVICE_LIBRARY_PATH}"
else
  log "Image requires TPU driver to be mounted at runtime from the host"
fi

log "Example Docker command for TPU usage:"
echo "docker run --rm --privileged \\
  --device=/dev/accel0 \\
  -e PJRT_DEVICE=TPU \\
  -e XLA_USE_BF16=1 \\
  -e TPU_NAME=local \\
  -e TF_PLUGGABLE_DEVICE_LIBRARY_PATH=\${TF_PLUGGABLE_DEVICE_LIBRARY_PATH} \\
  -v \${TF_PLUGGABLE_DEVICE_LIBRARY_PATH}:\${TF_PLUGGABLE_DEVICE_LIBRARY_PATH} \\
  -v /path/to/your/code:/app/code \\
  $FULL_IMAGE_NAME \\
  python /app/code/your_script.py"
