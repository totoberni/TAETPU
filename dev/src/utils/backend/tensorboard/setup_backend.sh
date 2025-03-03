# src/backend/tensorboard/setup_all.sh
#!/bin/bash

# Get script directory for absolute path references
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Import common functions
source "$PROJECT_DIR/src/utils/common_logging.sh"

# Main script
init_script 'TensorBoard backend complete setup'
ENV_FILE="$PROJECT_DIR/source/.env"
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" "BUCKET_NAME" "TPU_REGION" || exit 1

# Display banner
log "==============================================="
log "TensorBoard Backend Complete Setup"
log "==============================================="
log "This script will:"
log "1. Build and push the TensorBoard Docker image"
log "2. Set up a service account with proper permissions"
log "3. Deploy the TensorBoard service to Cloud Run"
log "==============================================="

# Confirm execution
read -p "Continue with setup? (y/n): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    log "Setup cancelled by user."
    exit 0
fi

# Step 1: Build Docker image
log "Step 1: Building TensorBoard Docker image..."
"$SCRIPT_DIR/build.sh" || {
    log_error "Failed to build Docker image. Aborting."
    exit 1
}

# Step 2: Set up service account
log "Step 2: Setting up service account..."
"$SCRIPT_DIR/setup_sa.sh" || {
    log_error "Failed to set up service account. Aborting."
    exit 1
}

# Step 3: Deploy to Cloud Run
log "Step 3: Deploying to Cloud Run..."
"$SCRIPT_DIR/deploy.sh" || {
    log_error "Failed to deploy to Cloud Run. Aborting."
    exit 1
}

log_success "TensorBoard backend setup completed successfully!"
log "You can now access your TensorBoard visualization through the Cloud Run URL"