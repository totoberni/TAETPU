#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$SCRIPT_DIR/common.sh"

# --- MAIN SCRIPT ---
init_script 'Docker image teardown'
ENV_FILE="$PROJECT_DIR/source/.env"

if [ -f "$ENV_FILE" ]; then
  load_env_vars "$ENV_FILE"
else
  log_error "ERROR: .env file not found at $ENV_FILE"
  exit 1
fi

# Validate required environment variables
check_env_vars "PROJECT_ID" || exit 1

# Display configuration 
display_config "PROJECT_ID"
log "- Image Name: tpu-hello-world"
log "- Image Tag: v1"

# Set up authentication
setup_auth

# Check Docker is installed for local cleanup
if command -v docker &> /dev/null; then
  # Clean up local Docker images
  log "Checking for local Docker image..."
  if docker image inspect tpu-hello-world:v1 &> /dev/null; then
    log "Removing local Docker image..."
    if docker rmi tpu-hello-world:v1 -f; then
      log_success "Local Docker image removed successfully"
    else
      log_warning "Failed to remove local Docker image"
    fi
  else
    log "Local Docker image not found. Skipping local cleanup."
  fi

  # Check for GCR-tagged local image
  if docker image inspect gcr.io/${PROJECT_ID}/tpu-hello-world:v1 &> /dev/null; then
    log "Removing local GCR-tagged Docker image..."
    if docker rmi gcr.io/${PROJECT_ID}/tpu-hello-world:v1 -f; then
      log_success "Local GCR-tagged Docker image removed successfully"
    else
      log_warning "Failed to remove local GCR-tagged Docker image"
    fi
  else
    log "Local GCR-tagged Docker image not found. Skipping."
  fi
else
  log_warning "Docker not found. Skipping local image cleanup."
fi

# Clean up Google Container Registry image
log "Checking for GCR image..."
if gcloud container images describe gcr.io/${PROJECT_ID}/tpu-hello-world:v1 &> /dev/null; then
  log "Removing image from Google Container Registry..."
  
  # Prompt user for confirmation
  read -p "This will DELETE the Docker image from GCR. Continue? (y/n): " -r
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    if gcloud container images delete gcr.io/${PROJECT_ID}/tpu-hello-world:v1 --force-delete-tags --quiet; then
      log_success "GCR image removed successfully"
    else
      log_warning "Failed to remove image from GCR"
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
  log_success "Docker cleanup completed"
else
  log "Docker system prune skipped"
fi

log "Docker image teardown process completed." 