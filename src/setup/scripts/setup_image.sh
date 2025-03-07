#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

# --- MAIN SCRIPT ---
init_script 'Docker image setup'
ENV_FILE="$PROJECT_DIR/source/.env"
TPU_ENV_FILE="$PROJECT_DIR/source/tpu.env"

# Load environment variables
load_env_vars "$ENV_FILE"

# Load TPU-specific environment variables if they exist
if [ -f "$TPU_ENV_FILE" ]; then
    log "Loading TPU-specific environment variables..."
    source "$TPU_ENV_FILE"
    log_success "TPU environment variables loaded successfully"
else
    log_warning "TPU environment file not found at $TPU_ENV_FILE"
    log_warning "Will use default TPU settings"
fi

# Validate required environment variables
check_env_vars "PROJECT_ID" || exit 1

# Display configuration
display_config "PROJECT_ID"
log "- Image Name: tpu-hello-world"
log "- Image Tag: v1"

# Set up authentication
setup_auth

# Check Docker is installed
if ! command -v docker &> /dev/null; then
  log_error "Docker is not installed or not in PATH"
  log_error "Please install Docker before running this script"
  exit 1
fi

# Verify that the Dockerfile exists
DOCKERFILE_PATH="$PROJECT_DIR/src/setup/docker/Dockerfile"
if [ ! -f "$DOCKERFILE_PATH" ]; then
  log_error "Dockerfile not found at $DOCKERFILE_PATH"
  exit 1
fi

# Verify that requirements.txt exists
REQUIREMENTS_PATH="$PROJECT_DIR/src/setup/docker/requirements.txt"
if [ ! -f "$REQUIREMENTS_PATH" ]; then
  log_error "requirements.txt not found at $REQUIREMENTS_PATH"
  exit 1
fi

# Ensure common_logging.sh is available for the container
COMMON_LOGGING_PATH="$PROJECT_DIR/src/utils/common_logging.sh"
DOCKER_UTILS_DIR="$PROJECT_DIR/src/setup/docker/utils"
if [ ! -d "$DOCKER_UTILS_DIR" ]; then
  log "Creating utils directory for Docker build context..."
  mkdir -p "$DOCKER_UTILS_DIR"
fi

log "Copying common_logging.sh to Docker build context..."
cp "$COMMON_LOGGING_PATH" "$DOCKER_UTILS_DIR/"

# Check if entrypoint.sh exists and make it executable
ENTRYPOINT_PATH="$PROJECT_DIR/src/setup/docker/entrypoint.sh"
if [ ! -f "$ENTRYPOINT_PATH" ]; then
  log_error "entrypoint.sh not found at $ENTRYPOINT_PATH"
  exit 1
else
  log "Making entrypoint.sh executable..."
  chmod +x "$ENTRYPOINT_PATH"
fi

# If tpu.env exists, copy it to the Docker build context
if [ -f "$TPU_ENV_FILE" ]; then
  log "Copying tpu.env to Docker build context..."
  cp "$TPU_ENV_FILE" "$PROJECT_DIR/src/setup/docker/tpu.env"
  log_success "TPU environment configuration copied to Docker build context"
else
  log_warning "TPU environment file not found at $TPU_ENV_FILE"
  log_warning "Docker container may not have optimal TPU configuration"
fi

# Create a temporary file with higher pip timeout to handle slow downloads
PIP_CONF=$(mktemp)
cat > "$PIP_CONF" << EOF
[global]
timeout = 300
retries = 5
EOF

# 1. Build Docker image with increased timeout and retries
log "Building Docker image..."
# Save current directory
CURRENT_DIR=$(pwd)
# Change to docker directory for the build
log "Changing to Docker directory: $PROJECT_DIR/src/setup/docker"
cd "$PROJECT_DIR/src/setup/docker"

# Build the Docker image with additional arguments for better stability
if docker build \
  --build-arg PIP_EXTRA_INDEX_URL=https://storage.googleapis.com/libtpu-releases/index.html \
  --build-arg PIP_CONF="$(cat $PIP_CONF)" \
  --network=host \
  --no-cache \
  -t tpu-hello-world:v1 .; then
  log_success "Docker image built successfully"
else
  log_error "Failed to build Docker image"
  # Return to original directory before exiting
  cd "$CURRENT_DIR"
  rm -f "$PIP_CONF"  # Clean up temporary file
  exit 1
fi

# Clean up temporary file
rm -f "$PIP_CONF"

# Return to original directory
cd "$CURRENT_DIR"

# 2. Authenticate with Google Container Registry
log "Authenticating with Google Container Registry..."
if gcloud auth configure-docker --quiet; then
  log "Authentication successful"
else
  log_error "Failed to authenticate with Google Container Registry"
  exit 1
fi

# 3. Tag Docker image
log "Tagging Docker image for GCR..."
if docker tag tpu-hello-world:v1 gcr.io/${PROJECT_ID}/tpu-hello-world:v1; then
  log "Image tagged successfully"
else
  log_error "Failed to tag Docker image"
  exit 1
fi

# 4. Push Docker image to GCR
log "Pushing Docker image to Google Container Registry..."
if docker push gcr.io/${PROJECT_ID}/tpu-hello-world:v1; then
  log_success "Docker image pushed successfully to gcr.io/${PROJECT_ID}/tpu-hello-world:v1"
else
  log_error "Failed to push Docker image to GCR"
  exit 1
fi

# 5. Provide instructions for running the container with --privileged
log "Docker image setup complete."
log "To run the container with TPU access, use the following command:"
log "docker run --privileged --rm \\"
log "  -e PJRT_DEVICE=TPU \\"
log "  -v /dev:/dev \\"
log "  -v /lib/libtpu.so:/lib/libtpu.so \\"
log "  -p 5000:5000 \\"
log "  -p 6006:6006 \\"
log "  gcr.io/${PROJECT_ID}/tpu-hello-world:v1"
log ""
log "You can now run setup_tpu.sh to create a TPU VM and pull this image." 