#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

# --- MAIN SCRIPT ---
init_script 'Docker image setup'
ENV_FILE="$PROJECT_DIR/source/.env"

# Load environment variables
load_env_vars "$ENV_FILE"

# Validate only the essential environment variable
check_env_vars "PROJECT_ID" || exit 1

# Display basic configuration
log "Docker image will be built for project: $PROJECT_ID"
log "Image name: gcr.io/$PROJECT_ID/tpu-hello-world:v1"

# Authenticate with GCP
setup_auth

# Check Docker is installed
if ! command -v docker &> /dev/null; then
  log_error "Docker is not installed or not in PATH"
  exit 1
fi

# Create temporary directory for docker build context
log "Preparing Docker build context..."
BUILD_DIR=$(mktemp -d)
log "Created temporary build directory: $BUILD_DIR"

# Ensure scripts have correct permissions
log "Setting up script permissions..."
chmod +x "$PROJECT_DIR/src/setup/docker/pull_docker_image.sh"
chmod +x "$PROJECT_DIR/src/setup/docker/run_container.sh"
chmod +x "$PROJECT_DIR/src/setup/docker/entrypoint.sh"

# Copy utility modules and scripts
log "Copying utility modules and scripts..."
mkdir -p "$BUILD_DIR/utils"
cp -r "$PROJECT_DIR/src/utils/"* "$BUILD_DIR/utils/"

# Copy full source code for embedding in the Docker image
log "Copying application source code..."
mkdir -p "$BUILD_DIR/src"
cp -r "$PROJECT_DIR/src/"* "$BUILD_DIR/src/"

# Copy source directory if it exists
if [ -d "$PROJECT_DIR/source" ]; then
  log "Copying source directory..."
  mkdir -p "$BUILD_DIR/source"
  cp -r "$PROJECT_DIR/source/"* "$BUILD_DIR/source/"
fi

# Set up scripts in the build context
log "Setting up scripts in build context..."
mkdir -p "$BUILD_DIR/app/scripts"
cp "$PROJECT_DIR/src/setup/docker/pull_docker_image.sh" "$BUILD_DIR/app/scripts/"
cp "$PROJECT_DIR/src/setup/docker/run_container.sh" "$BUILD_DIR/app/scripts/"
chmod +x "$BUILD_DIR/app/scripts/"*.sh

# Copy Dockerfile and requirements.txt
cp "$PROJECT_DIR/src/setup/docker/Dockerfile" "$BUILD_DIR/"
cp "$PROJECT_DIR/src/setup/docker/requirements.txt" "$BUILD_DIR/"
cp "$PROJECT_DIR/src/setup/docker/entrypoint.sh" "$BUILD_DIR/entrypoint.sh"
chmod +x "$BUILD_DIR/entrypoint.sh"

# Move to build directory and build image
cd "$BUILD_DIR"
log "Building Docker image from prepared context. This may take a while..."
if docker build -t tpu-hello-world:v1 .; then
  log_success "Docker image built successfully"
else
  log_error "Failed to build Docker image"
  cd "$PROJECT_DIR"  # Return to project directory
  rm -rf "$BUILD_DIR"  # Clean up temp directory
  exit 1
fi

# Return to project directory and clean up
cd "$PROJECT_DIR"
rm -rf "$BUILD_DIR"
log "Cleaned up temporary build directory"

# Configure Docker to use Google Container Registry
log "Configuring Docker for GCR..."
gcloud auth configure-docker gcr.io

# Tag the Docker image for GCR
log "Tagging Docker image for GCR..."
docker tag tpu-hello-world:v1 gcr.io/${PROJECT_ID}/tpu-hello-world:v1

# Push Docker image to GCR
log "Pushing Docker image to Google Container Registry..."
if docker push gcr.io/${PROJECT_ID}/tpu-hello-world:v1; then
  log_success "Docker image pushed successfully to gcr.io/${PROJECT_ID}/tpu-hello-world:v1." 
  log_success "You can now run setup_tpu.sh to create a TPU VM and pull this image."
else
  log_error "Failed to push Docker image to GCR"
  exit 1
fi