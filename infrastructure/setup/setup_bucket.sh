#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/infrastructure/utils/common.sh"

# --- MAIN SCRIPT ---
init_script 'GCS Bucket Setup'
ENV_FILE="$PROJECT_DIR/config/.env"

# Load environment variables
log "Loading environment variables..."
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" "BUCKET_NAME" "BUCKET_REGION" || exit 1

# Display configuration
display_config "PROJECT_ID" "BUCKET_NAME" "BUCKET_REGION"

# Set up authentication locally
setup_auth

# Check if bucket already exists
log "Checking if bucket 'gs://$BUCKET_NAME' exists..."
if gsutil ls -b "gs://$BUCKET_NAME" &> /dev/null; then
    log_warning "Bucket 'gs://$BUCKET_NAME' already exists. Skipping creation."
else
    # Create the bucket with appropriate parameters
    log "Creating bucket 'gs://$BUCKET_NAME'..."
    gsutil mb -p "$PROJECT_ID" -l "$BUCKET_REGION" "gs://$BUCKET_NAME"
    
    # Set default ACLs
    log "Setting default ACLs..."
    gsutil defacl set private "gs://$BUCKET_NAME"
    
    log_success "Bucket created successfully"
fi

# Create required directory structure in the bucket
log "Creating directory structure in bucket..."
# Create empty placeholder files to establish directory structure
touch /tmp/placeholder.txt

log "Creating /exp/datasets/ directory..."
gsutil cp /tmp/placeholder.txt "gs://$BUCKET_NAME/exp/datasets/placeholder.txt"

log "Creating /logs/ directory..."
gsutil cp /tmp/placeholder.txt "gs://$BUCKET_NAME/logs/placeholder.txt"

log "Creating /backend/ directory..."
gsutil cp /tmp/placeholder.txt "gs://$BUCKET_NAME/backend/placeholder.txt"

# Clean up
rm /tmp/placeholder.txt

log_success "Bucket directory structure created successfully"

# Note for TPU VM configuration
log_warning "NOTE: If you need to access this bucket from a TPU VM, please use:"
log_warning "  ./tools/gcs_ops/data_ops.sh fuse-vm"

log_success "GCS bucket setup completed successfully"
log_success "Bucket URL: gs://$BUCKET_NAME"
exit 0