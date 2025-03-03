#!/bin/bash

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source common logging functions
source "$PROJECT_DIR/src/utils/common_logging.sh"

# Default values
ENV_FILE="$PROJECT_DIR/source/.env"

# Load environment variables
load_env_vars "$ENV_FILE" || exit 1

# Verify environment variables
"$PROJECT_DIR/src/utils/verify.sh" --env || exit 1

# Display configuration
log "Setting up TPU with the following configuration:"
log "- PROJECT_ID: $PROJECT_ID"
log "- TPU_ZONE: $TPU_ZONE"
log "- TPU_TYPE: $TPU_TYPE"
log "- TPU_NAME: $TPU_NAME"
log "- TPU_VM_VERSION: $TPU_VM_VERSION"

# Set up authentication
setup_auth

# Set up Google Cloud project and zone
gcloud config set project "$PROJECT_ID"
gcloud config set compute/zone "$TPU_ZONE"

# Check if TPU VM already exists
log "Checking if TPU VM exists: $TPU_NAME"
if gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" &> /dev/null; then
  log_success "TPU VM already exists: $TPU_NAME"
else
  # Create TPU VM
  log "Creating TPU VM: $TPU_NAME..."
  
  CREATE_CMD="gcloud compute tpus tpu-vm create \"$TPU_NAME\" \
    --zone=\"$TPU_ZONE\" \
    --project=\"$PROJECT_ID\" \
    --accelerator-type=\"$TPU_TYPE\" \
    --version=\"$TPU_VM_VERSION\""
  
  # Add service account if specified
  if [[ -n "$SERVICE_ACCOUNT_EMAIL" ]]; then
    CREATE_CMD="$CREATE_CMD --service-account=\"$SERVICE_ACCOUNT_EMAIL\""
  fi
  
  # Execute the command
  eval "$CREATE_CMD"
  
  if [[ $? -ne 0 ]]; then
    log_error "Failed to create TPU VM"
    exit 1
  fi
  
  log_success "TPU VM created successfully"
fi

# Set up Docker permissions on TPU VM
log "Setting up Docker permissions on TPU VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
  --zone="$TPU_ZONE" \
  --project="$PROJECT_ID" \
  --command="sudo usermod -aG docker \$USER" || {
    log_warning "Failed to set up Docker permissions"
  }

# Copy service account key to TPU VM if specified
if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON" ]]; then
  log "Copying service account key to TPU VM..."
  gcloud compute tpus tpu-vm scp "$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON" "$TPU_NAME": \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" || {
      log_warning "Failed to copy service account key to TPU VM"
    }
    
  log "Configuring authentication on TPU VM..."
  gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --command="gcloud auth activate-service-account --key-file=$SERVICE_ACCOUNT_JSON && gcloud auth configure-docker --quiet" || {
      log_warning "Failed to configure authentication on TPU VM"
    }
else
  # Configure Docker authentication for GCR on TPU VM
  log "Configuring Docker authentication for GCR on TPU VM..."
  gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --command="gcloud auth configure-docker --quiet" || {
      log_warning "Failed to configure Docker authentication"
    }
fi

# Set TPU environment variables on VM
log "Setting TPU environment variables on VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
  --zone="$TPU_ZONE" \
  --project="$PROJECT_ID" \
  --command="echo 'export PJRT_DEVICE=TPU
export XLA_USE_BF16=1
export TPU_NAME=local
export TPU_LOAD_LIBRARY=0
export NEXT_PLUGGABLE_DEVICE_USE_C_API=true
export TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so' >> ~/.bashrc" || {
    log_warning "Failed to set TPU environment variables"
  }

# Success message
log_success "TPU VM setup complete: $TPU_NAME"
log "Connect to your TPU VM with:"
log "gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE --project=$PROJECT_ID"
log ""
log "To verify TPU functionality, run:"
log "$PROJECT_DIR/src/utils/verify.sh --tpu"

exit 0