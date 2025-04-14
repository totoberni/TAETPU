#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/infrastructure/utils/common.sh"

# --- MAIN SCRIPT ---
init_script 'Docker Image Teardown'

# Load environment variables
log "Loading environment variables..."
ENV_FILE="$PROJECT_DIR/config/.env"
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" || exit 1

# Set up Docker directory path
DOCKER_DIR="$PROJECT_DIR/infrastructure/docker"
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

# Function to delete by tag
delete_by_tag() {
    log "Fetching tags for repository $REPO_NAME..."
    TAGS=$(gcloud container images list-tags "$REPO_NAME" --format="value(tags)" 2>/dev/null || echo "")
    
    if [[ -z "$TAGS" ]]; then
        log_warning "No tags found for $REPO_NAME"
        return 1
    fi
    
    log_success "Found tags: $TAGS"
    
    # Delete each tag
    for tag in $TAGS; do
        log "Deleting tag: ${REPO_NAME}:${tag}"
        if gcloud container images delete "${REPO_NAME}:${tag}" --quiet --force-delete-tags; then
            log_success "Successfully deleted tag $tag"
        else
            log_warning "Failed to delete tag $tag"
        fi
    done
    
    return 0
}

# Function to delete by digest
delete_by_digest() {
    log "Fetching image digests..."
    
    # Get the list of digests
    DIGESTS=$(gcloud container images list-tags "$REPO_NAME" --format="value(digest)" 2>/dev/null || echo "")
    
    if [[ -z "$DIGESTS" ]]; then
        log_warning "No digests found for $REPO_NAME"
        return 1
    fi
    
    # Convert to array
    readarray -t DIGEST_ARRAY <<< "$DIGESTS"
    
    # Reverse the array (newest first)
    REVERSED_ARRAY=()
    for ((i=${#DIGEST_ARRAY[@]}-1; i>=0; i--)); do
        REVERSED_ARRAY+=("${DIGEST_ARRAY[i]}")
    done
    
    log_success "Found ${#REVERSED_ARRAY[@]} digests"
    
    # Try deleting digests up to 3 times
    local success=0
    local failed_digests=()
    
    for attempt in {1..3}; do
        log "Deletion attempt $attempt/3..."
        local current_success=0
        
        for i in "${!REVERSED_ARRAY[@]}"; do
            digest="${REVERSED_ARRAY[i]}"
            
            # Skip empty or already deleted digests
            if [[ -z "$digest" || "$digest" == "DELETED" ]]; then
                continue
            fi
            
            log "Deleting digest: $digest"
            if gcloud container images delete "${REPO_NAME}@${digest}" --quiet --force-delete-tags; then
                log_success "Successfully deleted digest $digest"
                # Mark as deleted
                REVERSED_ARRAY[i]="DELETED"
                current_success=1
                success=1
            else
                log_warning "Failed to delete digest $digest on attempt $attempt"
                # Add to failed digests if this is the final attempt
                if [[ $attempt -eq 3 ]]; then
                    failed_digests+=("$digest")
                fi
            fi
        done
        
        # If no progress was made in this attempt, break
        if [[ $current_success -eq 0 ]]; then
            log_warning "No digests could be deleted in attempt $attempt, stopping deletion process"
            break
        fi
        
        # Check if all digests are deleted
        local all_deleted=1
        for digest in "${REVERSED_ARRAY[@]}"; do
            if [[ "$digest" != "DELETED" && -n "$digest" ]]; then
                all_deleted=0
                break
            fi
        done
        
        if [[ $all_deleted -eq 1 ]]; then
            log_success "All digests have been deleted"
            break
        fi
    done
    
    # If there are failed digests, provide manual deletion instructions
    if [[ ${#failed_digests[@]} -gt 0 ]]; then
        log_warning "Some digests could not be automatically deleted. Please try the following manual commands:"
        echo ""
        echo "# Manual deletion commands:"
        echo "PROJECT_ID=$PROJECT_ID"
        echo "REPO_NAME=$REPO_NAME"
        echo ""
        echo "for digest in \\"
        for digest in "${failed_digests[@]}"; do
            echo "  $digest \\"
        done
        echo "; do"
        echo "  gcloud container images delete \"\${REPO_NAME}@\${digest}\" --quiet --force-delete-tags"
        echo "done"
        echo ""
    fi
    
    return $((1 - success))
}

# Check if the repository exists
log "Checking for Docker repository in Container Registry..."
if ! gcloud container images list --repository="$(dirname "$REPO_NAME")" --format="value(name)" 2>/dev/null | grep -q "$(basename "$REPO_NAME")"; then
    log_warning "Repository not found in GCR. Nothing to delete."
    exit 0
fi

log_success "Found repository $REPO_NAME"

# Confirm deletion with user
if ! confirm_delete "repository $REPO_NAME"; then
    log "Repository deletion cancelled by user"
    exit 0
fi

# Attempt repository deletion by deleting tags first
log "Attempting to delete repository by removing all tags..."
delete_by_tag || log_warning "Tag deletion method failed"

# Check if repository still exists
if gcloud container images list --repository="$(dirname "$REPO_NAME")" --format="value(name)" 2>/dev/null | grep -q "$(basename "$REPO_NAME")"; then
    log_warning "Repository still exists. Trying to delete by digest..."
    
    # Try deletion by digest
    delete_by_digest || log_warning "Digest deletion method also failed"
    
    # Final check
    if gcloud container images list --repository="$(dirname "$REPO_NAME")" --format="value(name)" 2>/dev/null | grep -q "$(basename "$REPO_NAME")"; then
        log_warning "Repository could not be completely removed"
    else
        log_success "Repository successfully removed from GCR"
    fi
else
    log_success "Repository successfully removed from GCR"
fi

# Clean up local Docker resources
log_section "Local Docker Cleanup"

# Get the repository base name without domain
REPO_BASE_NAME=$(basename "$REPO_NAME")

# Remove local images
log "Checking for local Docker images..."
LOCAL_IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "$REPO_BASE_NAME" 2>/dev/null || echo "")

if [[ -n "$LOCAL_IMAGES" ]]; then
    log "Found local images: $LOCAL_IMAGES"
    
    if confirm_delete "local Docker images"; then
        # Remove each image
        for img in $LOCAL_IMAGES; do
            docker rmi -f "$img" 2>/dev/null
        done
        log_success "Local images removed"
    fi
else
    log "No local Docker images found for $REPO_BASE_NAME"
fi

# Offer Docker system prune
if confirm_action "Run Docker system prune?" "n"; then
    docker system prune -f
    log_success "Docker system pruned"
fi

log_success "Docker image teardown completed"
exit 0