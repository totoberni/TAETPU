#!/bin/bash
# Docker Image Teardown Script - Removes Docker images from Google Container Registry
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
  
  # Display configuration
  log_section "Configuration"
  display_config "PROJECT_ID" "IMAGE_NAME"
  
  # Setup auth before running operations
  setup_auth
  
  # Check if the image exists
  if ! gcloud container images describe "$IMAGE_NAME" &>/dev/null; then
    log_error "Image $IMAGE_NAME does not exist"
    exit 1
  fi
}

# Delete all tagged images
function delete_tagged_images() {
  log_section "Deleting Tagged Images"
  
  # Get all tags first
  TAGS=$(gcloud container images list-tags "$IMAGE_NAME" --filter='tags:*' --format='get(tags)' --limit=unlimited)
  
  if [[ -z "$TAGS" ]]; then
    log_success "No tagged images found"
    return 0
  fi
  
  # Display tags to be deleted
  log "The following tags will be deleted:"
  for TAG in $TAGS; do
    log "  - $IMAGE_NAME:$TAG"
  done
  
  if ! confirm_action "Proceed with deletion of all tagged images?" "n"; then
    log "Deletion of tagged images cancelled by user"
    return 1
  fi
  
  # Delete each tagged image
  for TAG in $TAGS; do
    log "Deleting $IMAGE_NAME:$TAG"
    gcloud container images delete "$IMAGE_NAME:$TAG" --quiet --force-delete-tags
    if [[ $? -eq 0 ]]; then
      log_success "Successfully deleted $IMAGE_NAME:$TAG"
    else
      log_error "Failed to delete $IMAGE_NAME:$TAG"
    fi
  done
  
  log_success "Tagged image deletion completed"
  return 0
}

# Delete all untagged images by digest
function delete_by_digest() {
  log_section "Deleting Untagged Images"
  
  while true; do
    # List all untagged images and extract only the digest part
    log "Finding untagged images..."
    UNTAGGED_DIGESTS=$(gcloud container images list-tags "$IMAGE_NAME" --filter='-tags:*' --format='get(digest)' --limit=unlimited)
    
    if [[ -z "$UNTAGGED_DIGESTS" ]]; then
      log_success "No untagged images found"
      return 0
    fi
    
    # Count how many untagged images we found
    DIGEST_COUNT=$(echo "$UNTAGGED_DIGESTS" | wc -l)
    log "Found $DIGEST_COUNT untagged images"
    
    if ! confirm_action "Proceed with deletion of $DIGEST_COUNT untagged images?" "y"; then
      log "Deletion of untagged images cancelled by user"
      return 1
    fi
    
    # Delete each untagged image individually to better handle errors
    for FULL_DIGEST in $UNTAGGED_DIGESTS; do
      # Extract only the hash part without the "sha256:" prefix
      DIGEST_HASH=$(echo "$FULL_DIGEST" | sed 's/sha256://g')
      log "Deleting untagged image with digest: $DIGEST_HASH"
      
      # Use the correct format: IMAGE_NAME@sha256:HASH
      gcloud container images delete "${IMAGE_NAME}@sha256:${DIGEST_HASH}" --quiet --force-delete-tags
      
      if [[ $? -eq 0 ]]; then
        log_success "Successfully deleted image with digest: $DIGEST_HASH"
      else
        log_error "Failed to delete image with digest: $DIGEST_HASH"
      fi
    done
    
    # Check if any untagged images remain
    REMAINING=$(gcloud container images list-tags "$IMAGE_NAME" --filter='-tags:*' --format='get(digest)' --limit=unlimited)
    
    if [[ -z "$REMAINING" ]]; then
      log_success "Successfully deleted all untagged images"
      return 0
    else
      log_warning "Some untagged images still remain"
      if ! confirm_action "Retry deletion of untagged images?" "y"; then
        log "Deletion of untagged images cancelled by user"
        return 1
      fi
    fi
  done
}

# Main function
function main() {
  # Initialize
  init_script 'Docker Image Teardown'
  
  # Load environment variables
  load_env_vars "$ENV_FILE"
  
  # Validate environment
  validate_environment
  
  # First delete tagged images
  delete_tagged_images
  
  # Then delete untagged images
  delete_by_digest
  
  # Complete
  log_success "Docker image teardown completed for $IMAGE_NAME"
  log_elapsed_time
}

# ---- Main Execution ----
main