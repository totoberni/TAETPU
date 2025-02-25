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
log 'Starting Docker image teardown process...'

# Load environment variables if .env exists
if [ -f "../source/.env" ]; then
  log 'Loading environment variables...'
  source ../source/.env
  log 'Environment variables loaded successfully'
else
  log "ERROR: .env file not found"
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
if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "../source/$SERVICE_ACCOUNT_JSON" ]]; then
  log 'Setting up service account credentials...'
  export GOOGLE_APPLICATION_CREDENTIALS="$(pwd)/../source/$SERVICE_ACCOUNT_JSON"
  gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
  log 'Service account authentication successful'
fi

# Check Docker is installed for local cleanup
if command -v docker &> /dev/null; then
  # Clean up local Docker images
  log "Checking for local Docker image..."
  if docker image inspect tpu-hello-world:v1 &> /dev/null; then
    log "Removing local Docker image..."
    if docker rmi tpu-hello-world:v1 -f; then
      log "Local Docker image removed successfully"
    else
      log "WARNING: Failed to remove local Docker image"
    fi
  else
    log "Local Docker image not found. Skipping local cleanup."
  fi

  # Check for GCR-tagged local image
  if docker image inspect gcr.io/${PROJECT_ID}/tpu-hello-world:v1 &> /dev/null; then
    log "Removing local GCR-tagged Docker image..."
    if docker rmi gcr.io/${PROJECT_ID}/tpu-hello-world:v1 -f; then
      log "Local GCR-tagged Docker image removed successfully"
    else
      log "WARNING: Failed to remove local GCR-tagged Docker image"
    fi
  else
    log "Local GCR-tagged Docker image not found. Skipping."
  fi
else
  log "Docker not found. Skipping local image cleanup."
fi

# Clean up Google Container Registry image
log "Checking for GCR image..."
if gcloud container images describe gcr.io/${PROJECT_ID}/tpu-hello-world:v1 &> /dev/null; then
  log "Removing image from Google Container Registry..."
  
  # Prompt user for confirmation
  read -p "This will DELETE the Docker image from GCR. Continue? (y/n): " -r
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    if gcloud container images delete gcr.io/${PROJECT_ID}/tpu-hello-world:v1 --force-delete-tags --quiet; then
      log "GCR image removed successfully"
    else
      log "WARNING: Failed to remove image from GCR"
    fi
  else
    log "GCR image deletion cancelled by user"
  fi
else
  log "Image not found in GCR. Skipping remote cleanup."
fi

# Offer to run a Docker system prune
log "Docker system prune can remove all unused containers, networks, images (both dangling and unreferenced), and optionally, volumes."
read -p "Would you like to run 'docker system prune' to clean up unused Docker resources? (y/n): " -r
if [[ $REPLY =~ ^[Yy]$ ]]; then
  log "Running Docker system prune..."
  docker system prune -f
  log "Docker cleanup completed"
else
  log "Docker system prune skipped"
fi

log "Docker image teardown process completed." 