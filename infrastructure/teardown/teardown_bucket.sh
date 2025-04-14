#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/infrastructure/utils/common.sh"

# --- MAIN SCRIPT ---
init_script 'GCS Bucket Teardown'
ENV_FILE="$PROJECT_DIR/config/.env"

# Load environment variables
log "Loading environment variables..."
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" "BUCKET_NAME" || exit 1

# Display configuration
display_config "PROJECT_ID" "BUCKET_NAME"

# Set up authentication locally
setup_auth

# Check if bucket exists
log "Checking if bucket 'gs://$BUCKET_NAME' exists..."
if ! gsutil ls -b "gs://$BUCKET_NAME" &> /dev/null; then
    log_warning "Bucket 'gs://$BUCKET_NAME' does not exist. Nothing to delete."
    exit 0
fi

# Confirm deletion
read -p "Are you sure you want to delete bucket 'gs://$BUCKET_NAME' and ALL its contents? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
    log "Deletion cancelled."
    exit 0
fi

# Delete the bucket and all its contents
log "Deleting bucket 'gs://$BUCKET_NAME' and all its contents..."
gsutil -m rm -r "gs://$BUCKET_NAME"

# Verify deletion
if ! gsutil ls -b "gs://$BUCKET_NAME" &> /dev/null; then
    log_success "Bucket deleted successfully"
else
    log_error "Failed to delete bucket. Please check permissions and try again."
    exit 1
fi

log_success "GCS bucket teardown completed successfully"
exit 0