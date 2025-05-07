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

# ---- Flag Variables ----
DIGEST_ONLY=false      # Run only delete_by_digest step
REVERSE_DIGEST=false   # Reverse digest order when deleting
RANDOMIZE_DIGEST=false # Randomize digest order when deleting
LOCAL_ONLY=false       # Delete only local resources
RUN_ALL=true           # Default: run all steps

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
    log_warning "Image $IMAGE_NAME does not exist in GCR"
  fi
}

# Delete local Docker resources
function delete_local_resources() {
  log_section "Deleting Local Docker Resources"
  
  log "Checking for local image copies..."
  LOCAL_IMAGES=$(docker images | grep -E "$(basename $IMAGE_NAME)" || echo "")
  
  if [[ -z "$LOCAL_IMAGES" ]]; then
    log_success "No local Docker images found matching $(basename $IMAGE_NAME)"
  else
    echo "Found local Docker images:"
    echo "$LOCAL_IMAGES"
    
    if confirm_action "Delete all local Docker images for $(basename $IMAGE_NAME)?" "n"; then
      # Remove all matching local images
      log "Removing local images..."
      docker rmi $(docker images | grep -E "$(basename $IMAGE_NAME)" | awk '{print $1":"$2}') 2>/dev/null || true
      log_success "Local Docker images cleanup completed"
    else
      log "Local image deletion cancelled by user"
    fi
  fi
  
  # Offer to run docker system prune for comprehensive cleanup
  log "Checking for additional Docker resources that can be cleaned..."
  
  # Show Docker resources summary
  echo "Current Docker resource usage:"
  echo "=============================="
  echo "CONTAINERS:"
  docker ps -a --format "table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}" | head -n 20
  echo "IMAGES:"
  docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" | head -n 10
  echo "VOLUMES:"
  docker volume ls --format "table {{.Name}}\t{{.Driver}}\t{{.Mountpoint}}" | head -n 10
  echo "=============================="
  
  if confirm_action "Run system-wide Docker cleanup (will remove unused containers, networks, images and dangling volumes)?" "n"; then
    log "Performing comprehensive Docker system prune..."
    # -a removes all unused images, not just dangling ones
    # --volumes removes unused volumes
    docker system prune -a --volumes -f
    log_success "Docker system prune completed"
  else
    log "System-wide cleanup skipped"
  fi
  
  return 0
}

# Delete all tagged images
function delete_tagged_images() {
  log_section "Deleting Tagged Images"
  
  # Get all tags first
  TAGS=$(gcloud container images list-tags "$IMAGE_NAME" --filter='tags:*' --format='get(tags)' --limit=unlimited)
  
  if [[ -z "$TAGS" ]]; then
    log_success "No tagged images found"
  else
    # Display tags to be deleted
    log "The following tags will be deleted:"
    for TAG in $TAGS; do
      log "  - $IMAGE_NAME:$TAG"
    done
    
    if confirm_action "Proceed with deletion of all tagged images?" "n"; then
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
    else
      log "Deletion of tagged images cancelled by user"
    fi
  fi
  
  # Offer to run docker image prune for repository cleanup
  if confirm_action "Clean up any dangling images in the repository?" "n"; then
    log "Pruning dangling images from the repository..."
    
    # Use gcloud to clean up dangling artifacts
    gcloud container images list-tags "$IMAGE_NAME" --filter='-tags:*' --format='get(digest)' --limit=unlimited | while read DIGEST; do
      if [[ -n "$DIGEST" ]]; then
        log "Removing dangling image: $DIGEST"
        gcloud container images delete "${IMAGE_NAME}@${DIGEST}" --quiet --force-delete-tags || true
      fi
    done
    
    # Also run local docker image prune
    log "Pruning local dangling images..."
    docker image prune -f
    
    log_success "Image pruning completed"
  else
    log "Repository cleanup skipped"
  fi
  
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
      break
    fi
    
    # Process digest list based on flags
    if [[ "$RANDOMIZE_DIGEST" == true ]]; then
      log "Randomizing digest list to help avoid parent relationship errors"
      # Create temporary file with digests and randomize with sort
      echo "$UNTAGGED_DIGESTS" > /tmp/digest_list.txt
      UNTAGGED_DIGESTS=$(sort -R /tmp/digest_list.txt)
      rm -f /tmp/digest_list.txt
    elif [[ "$REVERSE_DIGEST" == true ]]; then
      log "Reversing digest list to handle parent relationships"
      UNTAGGED_DIGESTS=$(echo "$UNTAGGED_DIGESTS" | tac)
    fi
    
    # Count how many untagged images we found
    DIGEST_COUNT=$(echo "$UNTAGGED_DIGESTS" | wc -l)
    log "Found $DIGEST_COUNT untagged images"
    
    if ! confirm_action "Proceed with deletion of $DIGEST_COUNT untagged images?" "y"; then
      log "Deletion of untagged images cancelled by user"
      break
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
      break
    else
      log_warning "Some untagged images still remain"
      if ! confirm_action "Retry deletion of untagged images?" "y"; then
        log "Deletion of untagged images cancelled by user"
        break
      fi
    fi
  done
  
  # Offer to run docker image prune for additional cleanup
  if confirm_action "Perform additional cleanup of dangling Docker images?" "n"; then
    log "Pruning dangling images locally..."
    docker image prune -f
    
    log "Checking for any other artifacts in the repository..."
    RELATED_IMAGES=$(gcloud container images list --repository=${IMAGE_NAME%/*} --format="value(name)" 2>/dev/null || echo "")
    
    if [[ -n "$RELATED_IMAGES" ]]; then
      echo "Found related repository images:"
      echo "$RELATED_IMAGES"
      
      if confirm_action "Would you like to check these repositories for cleanup as well?" "n"; then
        for REPO in $RELATED_IMAGES; do
          log "Cleaning up dangling images in $REPO..."
          gcloud container images list-tags "$REPO" --filter='-tags:*' --format='get(digest)' --limit=unlimited | while read DIGEST; do
            if [[ -n "$DIGEST" ]]; then
              log "Removing dangling image: $DIGEST from $REPO"
              gcloud container images delete "${REPO}@${DIGEST}" --quiet --force-delete-tags || true
            fi
          done
        done
      fi
    fi
    
    log_success "Additional cleanup completed"
  else
    log "Additional cleanup skipped"
  fi
  
  return 0
}

# Process command line arguments
function process_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --digest)
        DIGEST_ONLY=true
        RUN_ALL=false
        shift
        ;;
      --reverse-digest)
        REVERSE_DIGEST=true
        shift
        ;;
      --random)
        RANDOMIZE_DIGEST=true
        shift
        ;;
      --local)
        LOCAL_ONLY=true
        RUN_ALL=false
        shift
        ;;
      -h|--help)
        echo "Usage: $0 [options]"
        echo "Options:"
        echo "  --digest           Run only digest deletion step (untagged images)"
        echo "  --reverse-digest   Process digests in reverse order (useful for parent relation errors)"
        echo "  --random           Randomize digest order before deletion (can help with parent dependencies)"
        echo "  --local            Delete only local Docker images"
        echo "  -h, --help         Show this help message"
        echo ""
        echo "Examples:"
        echo "  $0                      Run all cleanup operations"
        echo "  $0 --digest             Delete only untagged images"
        echo "  $0 --digest --random    Delete untagged images in random order"
        echo "  $0 --digest --reverse-digest   Delete untagged images in reverse order"
        echo "  $0 --local              Delete only local Docker images"
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        echo "Use --help for available options"
        exit 1
        ;;
    esac
  done
  
  # Handle mutually exclusive options
  if [[ "$REVERSE_DIGEST" == true && "$RANDOMIZE_DIGEST" == true ]]; then
    log_warning "Both --reverse-digest and --random are specified. Using --random (randomized order)"
    REVERSE_DIGEST=false
  fi
}

# Main function
function main() {
  # Initialize
  init_script 'Docker Image Teardown'
  
  # Process command line arguments
  process_args "$@"
  
  # Load environment variables
  load_env_vars "$ENV_FILE"
  
  # Validate environment
  validate_environment
  
  # Run selected operations based on flags
  if [[ "$LOCAL_ONLY" == true ]]; then
    delete_local_resources
  elif [[ "$DIGEST_ONLY" == true ]]; then
    delete_by_digest
  elif [[ "$RUN_ALL" == true ]]; then
    # Run all steps in default order
    delete_tagged_images
    delete_by_digest
    delete_local_resources
  fi
  
  # Complete
  log_success "Docker image teardown completed for $IMAGE_NAME"
  log_elapsed_time
}

# ---- Main Execution ----
main "$@"