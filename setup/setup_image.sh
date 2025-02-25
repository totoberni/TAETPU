#!/bin/bash

# --- HELPER FUNCTIONS ---
log() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] $1"
}

handle_error() {
  local line_no=$1
  local error_code=$2
  log "ERROR: Command failed at line $line_no with exit code $error_code"
  exit $error_code
}

# Set up error trapping
trap 'handle_error ${LINENO} $?' ERR

# --- MAIN SCRIPT ---
log 'Starting Docker image setup process...'

# Load environment variables if .env exists
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
ENV_FILE="$SCRIPT_DIR/../source/.env"

if [ -f "$ENV_FILE" ]; then
  log 'Loading environment variables...'
  source "$ENV_FILE"
  log 'Environment variables loaded successfully'
else
  log "ERROR: .env file not found at $ENV_FILE"
  exit 1
fi

# Validate required environment variables
if [[ -z "$PROJECT_ID" ]]; then
  log "ERROR: PROJECT_ID environment variable is not set"
  exit 1
fi

log "Configuration:"
log "- Project ID: $PROJECT_ID"
log "- Image Name: tpu-hello-world"
log "- Image Tag: v1"

# Set up authentication if provided
if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$SCRIPT_DIR/../source/$SERVICE_ACCOUNT_JSON" ]]; then
  log 'Setting up service account credentials...'
  export GOOGLE_APPLICATION_CREDENTIALS="$SCRIPT_DIR/../source/$SERVICE_ACCOUNT_JSON"
  gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
  log 'Service account authentication successful'
fi

# Check Docker is installed
if ! command -v docker &> /dev/null; then
  log "ERROR: Docker is not installed or not in PATH"
  log "Please install Docker before running this script"
  exit 1
fi

# 1. Build Docker image
log "Building Docker image..."
# Save current directory
CURRENT_DIR=$(pwd)
# Change to project root directory for the build
PROJECT_ROOT="$SCRIPT_DIR/.."
log "Changing to project root directory: $PROJECT_ROOT"
cd "$PROJECT_ROOT"

# Build the Docker image
if docker build -t tpu-hello-world:v1 -f setup/docker/Dockerfile .; then
  log "Docker image built successfully"
else
  log "ERROR: Failed to build Docker image"
  # Return to original directory before exiting
  cd "$CURRENT_DIR"
  exit 1
fi

# Return to original directory
cd "$CURRENT_DIR"

# 2. Authenticate with Google Container Registry
log "Authenticating with Google Container Registry..."
if gcloud auth configure-docker --quiet; then
  log "Authentication successful"
else
  log "ERROR: Failed to authenticate with Google Container Registry"
  exit 1
fi

# 3. Tag Docker image
log "Tagging Docker image for GCR..."
if docker tag tpu-hello-world:v1 gcr.io/${PROJECT_ID}/tpu-hello-world:v1; then
  log "Image tagged successfully"
else
  log "ERROR: Failed to tag Docker image"
  exit 1
fi

# 4. Push Docker image to GCR
log "Pushing Docker image to Google Container Registry..."
if docker push gcr.io/${PROJECT_ID}/tpu-hello-world:v1; then
  log "Docker image pushed successfully to gcr.io/${PROJECT_ID}/tpu-hello-world:v1"
else
  log "ERROR: Failed to push Docker image to GCR"
  exit 1
fi

log "Docker image setup complete."
log "You can now run setup_tpu.sh to create a TPU VM and pull this image." 