#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common.sh"

# --- MAIN SCRIPT ---   
init_script 'Docker Image Teardown'

# Load environment variables
log "Loading environment variables..."
ENV_FILE="$PROJECT_DIR/source/.env"
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" || exit 1

# Get docker-compose path and parse image info
DOCKER_DIR="$PROJECT_DIR/src/setup/docker"
DOCKER_COMPOSE_FILE="$DOCKER_DIR/docker-compose.yml"

# Extract image details from docker-compose.yml if available
if [[ -f "$DOCKER_COMPOSE_FILE" ]]; then
    # Extract the full image reference including tag
    FULL_IMAGE_REF=$(grep -o 'image: eu.gcr.io/${PROJECT_ID}/[^[:space:]]*' "$DOCKER_COMPOSE_FILE" | sed 's/image: //')
    # Replace environment variables
    FULL_IMAGE_REF=$(eval echo "$FULL_IMAGE_REF")
    
    # Parse repository name (without tag)
    REPO_NAME=$(echo "$FULL_IMAGE_REF" | cut -d':' -f1)
    log_success "Found repository in docker-compose.yml: $REPO_NAME"
else

    # Fallback to default if docker-compose.yml doesn't exist
    REPO_NAME="eu.gcr.io/${PROJECT_ID}/tae-tpu"
    log_warning "docker-compose.yml not found. Using default repository: $REPO_NAME"
fi

# Set up authentication
setup_auth

# Display configuration
log_section "Configuration"
log "Project ID: $PROJECT_ID"
log "Repository: $REPO_NAME"

# Check if the repository exists
log "Checking for Docker repository in Container Registry..."
if gcloud container images list --repository="$(dirname "$REPO_NAME")" --format="value(name)" | grep -q "$(basename "$REPO_NAME")"; then
    log_success "Found repository $REPO_NAME"
    
    # Confirm deletion with user
    if confirm_delete "repository $REPO_NAME and all its tags"; then
        # Delete the entire repository with all tags
        log "Deleting repository $REPO_NAME with all its tags..."
        if gcloud container images delete "$REPO_NAME" --quiet --force-delete-tags; then
            log_success "Repository deleted successfully from GCR"
        else
            # If the above fails, ask user if they want to proceed with manual deletion
            log_warning "Failed to delete entire repository."
            
            if confirm_action "Would you like to attempt manual deletion by digest?" "y"; then
                log "Proceeding with manual deletion..."
                
                # Try up to 3 iterations to handle cross-referenced layers
                MAX_ITERATIONS=3
                for ((i=1; i<=MAX_ITERATIONS; i++)); do
                    log "Manual deletion attempt $i of $MAX_ITERATIONS"
                    
                    gcloud container images list-tags "eu.gcr.io/infra-tempo401122/tae-tpu" --format="value(digest)"
                    # Get all digests
                    DIGESTS=$(gcloud container images list-tags "$REPO_NAME" --format="value(digest)" 2>/dev/null)
                    
                    # If no digests remain, we're done
                    if [ -z "$DIGESTS" ]; then
                        log_success "All images deleted successfully"
                        break
                    fi
                    
                    # Delete each digest
                    for digest in $DIGESTS; do
                        log "Deleting digest: $digest"
                        gcloud container images delete "${REPO_NAME}@${digest}" --force-delete-tags --quiet || \
                            log_warning "Failed to delete ${digest}, will retry in next round"
                    done
                    
                    # Check if any digests remain
                    REMAINING=$(gcloud container images list-tags "$REPO_NAME" --format="value(digest)" 2>/dev/null)
                    if [ -z "$REMAINING" ]; then
                        log_success "All images deleted successfully"
                        break
                    else
                        log_warning "Some images remain, will try again in next iteration"
                        # Wait a moment before next attempt
                        sleep 2
                    fi
                done
                
                # Final check
                if gcloud container images list --repository="$(dirname "$REPO_NAME")" --format="value(name)" | grep -q "$(basename "$REPO_NAME")"; then
                    log_warning "Could not delete all images after $MAX_ITERATIONS attempts"
                else
                    log_success "Repository successfully removed from GCR"
                fi
            else
                log "Manual deletion skipped by user"
            fi
        fi
    else
        log "Repository deletion cancelled by user"
        exit 0
    fi
else
    log_warning "Repository not found in GCR. Nothing to delete."
fi

# Clean up local Docker resources
log_section "Local Docker Cleanup"
log "Cleaning up local Docker resources..."

# Remove local image if it exists
if docker images | grep -q "$(basename "$REPO_NAME")"; then
    if confirm_delete "local Docker images for $(basename "$REPO_NAME")"; then
        log "Removing local Docker image..."
        docker rmi $(docker images | grep "$(basename "$REPO_NAME")" | awk '{print $1":"$2}') 2>/dev/null || true
        log_success "Local Docker images removed"
    else
        log "Local image deletion cancelled by user"
    fi
fi

# Ask for confirmation before pruning Docker system
if confirm_action "Would you like to run Docker system prune to clean up unused resources?" "n"; then
    log "Pruning Docker system..."
    docker system prune -f
    log_success "Docker system pruned"
else
    log "Docker system prune skipped by user"
fi

log_success "Docker image teardown completed"
exit 0