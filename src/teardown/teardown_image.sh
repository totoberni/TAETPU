#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common.sh"

# --- MAIN SCRIPT ---
init_script 'Docker Image Teardown'

# Load environment variables
log "Loading environment variables..."
ENV_FILE="$PROJECT_DIR/source/.env"
load_env_vars "$ENV_FILE"

# Get docker-compose path and parse image info
DOCKER_DIR="$PROJECT_DIR/src/setup/docker"
DOCKER_COMPOSE_FILE="$DOCKER_DIR/docker-compose.yml"

# Validate required environment variables
check_env_vars "PROJECT_ID" || exit 1

# Extract image details from docker-compose.yml if available
if [[ -f "$DOCKER_COMPOSE_FILE" ]]; then
    IMAGE_TAG=$(grep -o 'image: eu.gcr.io/${PROJECT_ID}/[^:]*:[^"]*' "$DOCKER_COMPOSE_FILE" | sed 's/image: //')
    # Replace environment variables
    IMAGE_TAG=$(eval echo "$IMAGE_TAG")
    REPO_NAME=$(echo "$IMAGE_TAG" | cut -d':' -f1)
    log_success "Found image reference in docker-compose.yml: $IMAGE_TAG"
else
    # Fallback to default if docker-compose.yml doesn't exist or doesn't contain the image
    REPO_NAME="eu.gcr.io/${PROJECT_ID}/tae-tpu"
    IMAGE_TAG="${REPO_NAME}:v1"
    log_warning "docker-compose.yml not found or doesn't contain image reference. Using default: $IMAGE_TAG"
fi

# Set up authentication
setup_auth

# Display configuration
log_section "Configuration"
log "Project ID: $PROJECT_ID"
log "Image to remove: $IMAGE_TAG"

# Check if the repository exists using list command
log "Checking for Docker images in Container Registry..."
if gcloud container images list --repository="$(dirname "$REPO_NAME")" --format="value(name)" | grep -q "$(basename "$REPO_NAME")"; then
    log_success "Found repository $REPO_NAME"
    
    # Check for image tags
    log "Checking for tags in $REPO_NAME..."
    if gcloud container images list-tags "$REPO_NAME" --format="value(tags)" | grep -q "v1"; then
        log "Found image $IMAGE_TAG"
        
        # Confirm deletion
        read -p "Are you sure you want to delete this Docker image from GCR? (y/n): " confirm
        if [[ "$confirm" == "y" ]]; then
            log "Deleting Docker image $IMAGE_TAG..."
            if gcloud container images delete "$IMAGE_TAG" --quiet --force-delete-tags; then
                log_success "Docker image deleted successfully from GCR"
            else
                log_warning "Failed to delete Docker image from GCR"
            fi
        else
            log "GCR deletion cancelled."
        fi
    else
        log_warning "No tag 'v1' found in repository $REPO_NAME"
    fi
else
    log_warning "Repository not found in GCR. Nothing to delete."
fi

# Offer Docker system prune to clean up local resources
if command -v docker &> /dev/null; then
    log_section "Docker System Cleanup"
    log "Docker system prune can remove all unused containers, networks, images, and volumes."
    read -p "Would you like to run 'docker system prune' to clean up unused Docker resources? (y/n): " prune_confirm
    if [[ "$prune_confirm" =~ ^[Yy]$ ]]; then
        log "Running Docker system prune..."
        docker system prune -f
        
        # Offer volume pruning
        read -p "Would you like to prune Docker volumes as well? (y/n): " volume_confirm
        if [[ "$volume_confirm" =~ ^[Yy]$ ]]; then
            log "Pruning Docker volumes..."
            docker volume prune -f
            log_success "Docker volumes pruned successfully"
        else
            log "Docker volume pruning skipped"
        fi
        
        log_success "Docker cleanup completed"
    else
        log "Docker system prune skipped"
    fi
fi

log_success "Docker image teardown completed"
exit 0