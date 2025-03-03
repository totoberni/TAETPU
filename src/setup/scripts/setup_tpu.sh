#!/bin/bash

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source common logging functions
source "$PROJECT_DIR/src/utils/common_logging.sh"

# Default values
ENV_FILE="$PROJECT_DIR/source/.env"

# Initialize the script
init_script "TPU VM Setup"

# Load environment variables
load_env_vars "$ENV_FILE" || exit 1

# Verify environment variables
"$PROJECT_DIR/src/utils/verify.sh" --env || exit 1

# Display configuration
log_section "TPU Configuration"
display_config "PROJECT_ID" "TPU_ZONE" "TPU_TYPE" "TPU_NAME" "TPU_VM_VERSION" "TF_VERSION"

# Set up authentication
setup_auth

# Set up Google Cloud project and zone
gcloud config set project "$PROJECT_ID"
gcloud config set compute/zone "$TPU_ZONE"

# Check if TPU VM already exists
log "Checking if TPU VM exists: $TPU_NAME"
if verify_tpu_existence "$TPU_NAME" "$TPU_ZONE" "$PROJECT_ID"; then
  log_success "TPU VM already exists: $TPU_NAME"
else
  # Create TPU VM with the correct software version
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

# Check TPU VM state
if ! verify_tpu_state "$TPU_NAME" "$TPU_ZONE" "$PROJECT_ID"; then
  log_error "TPU VM is not in READY state. Please check the TPU VM status and try again."
  exit 1
fi

# Set up Docker permissions on TPU VM
log "Setting up Docker permissions on TPU VM..."
ssh_with_timeout "sudo usermod -aG docker \$USER" 60 || {
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
  ssh_with_timeout "gcloud auth activate-service-account --key-file=$SERVICE_ACCOUNT_JSON && gcloud auth configure-docker --quiet" 60 || {
    log_warning "Failed to configure authentication on TPU VM"
  }
else
  # Configure Docker authentication for GCR on TPU VM
  log "Configuring Docker authentication for GCR on TPU VM..."
  ssh_with_timeout "gcloud auth configure-docker --quiet" 60 || {
    log_warning "Failed to configure Docker authentication"
  }
fi

# Install additional Python dependencies on TPU VM
log "Installing additional Python libraries on TPU VM..."
# Copy requirements.txt to TPU VM
REQUIREMENTS_PATH="$PROJECT_DIR/src/setup/docker/requirements.txt"
if [[ -f "$REQUIREMENTS_PATH" ]]; then
  gcloud compute tpus tpu-vm scp "$REQUIREMENTS_PATH" "$TPU_NAME":/tmp/requirements.txt \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" || {
      log_warning "Failed to copy requirements file to TPU VM"
    }

  # Install dependencies
  ssh_with_timeout "pip install -r /tmp/requirements.txt" 300 || {
    log_warning "Failed to install Python dependencies on TPU VM"
  }
else
  log_warning "Requirements file not found at $REQUIREMENTS_PATH"
fi

# Set TPU environment variables on VM based on documentation
log "Setting TPU environment variables on VM..."
ssh_with_timeout "echo 'export TPU_NAME=local
export PJRT_DEVICE=TPU
export NEXT_PLUGGABLE_DEVICE_USE_C_API=true
export TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so' >> ~/.bashrc" 60 || {
  log_warning "Failed to set TPU environment variables"
}

# Success message
log_success "TPU VM setup complete: $TPU_NAME"
log_section "Next Steps"
log "Connect to your TPU VM with:"
log "gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE --project=$PROJECT_ID"
log ""
log "To verify TPU functionality, run:"
log "$PROJECT_DIR/src/utils/verify.sh --tpu"

log_elapsed_time
exit 0