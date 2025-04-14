#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common.sh"

# --- MAIN SCRIPT ---
init_script 'GCS Bucket Setup'
ENV_FILE="$PROJECT_DIR/source/.env"

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

# If TPU exists, configure it to access the bucket
if [[ -n "$TPU_NAME" && -n "$TPU_ZONE" ]]; then
    log "Checking if TPU '$TPU_NAME' exists..."
    if gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" &> /dev/null; then
        log "TPU VM exists. Configuring access to GCS bucket..."
        
        # Configure gsutil on TPU VM
        vmssh "gcloud config set project $PROJECT_ID"
        
        log_success "TPU VM configured to access GCS bucket"
    else
        log "TPU VM does not exist or is not accessible. Skipping TPU configuration."
    fi
else
    log "TPU_NAME or TPU_ZONE not set. Skipping TPU configuration."
fi

log_success "GCS bucket setup completed successfully"
log_success "Bucket URL: gs://$BUCKET_NAME"
exit 0