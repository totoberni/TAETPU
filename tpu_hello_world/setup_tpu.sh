#!/bin/bash

# --- HELPER FUNCTIONS ---
log() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] $1"
}

handle_error() {
  local line_no=$1
  local error_code=$2
  log "ERROR: Command failed at line $line_no with exit code $error_code"
  exit $error_code
}

# Set up error trapping
trap 'handle_error ${LINENO} $?' ERR

# --- MAIN SCRIPT ---
log 'Starting TPU setup process...'

log 'Loading environment variables...'
source .env
log 'Environment variables loaded successfully'

# Validate required environment variables
if [[ -z "$PROJECT_ID" || -z "$TPU_ZONE" || -z "$TPU_TYPE" || -z "$TPU_NAME" || -z "$TPU_RUNTIME_VERSION" ]]; then
  log "ERROR: Required environment variables are missing"
  log "Ensure PROJECT_ID, TPU_ZONE, TPU_TYPE, TPU_NAME, and TPU_RUNTIME_VERSION are set in .env"
  exit 1
fi

log "Configuration:"
log "- Project ID: $PROJECT_ID"
log "- TPU Zone: $TPU_ZONE"
log "- TPU Type: $TPU_TYPE"
log "- TPU Name: $TPU_NAME"
log "- Runtime Version: $TPU_RUNTIME_VERSION"

# Set up authentication if provided
if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$SERVICE_ACCOUNT_JSON" ]]; then
  log 'Setting up service account credentials...'
  export GOOGLE_APPLICATION_CREDENTIALS="$(pwd)/$SERVICE_ACCOUNT_JSON"
  gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
  log 'Service account authentication successful'
fi

log 'Configuring Google Cloud project and zone...'
gcloud config set project "$PROJECT_ID"
gcloud config set compute/zone "$TPU_ZONE"
log "Project and zone configured: $PROJECT_ID in $TPU_ZONE"

# Check if the TPU already exists
if gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" &> /dev/null; then
  log "TPU '$TPU_NAME' already exists. Skipping TPU creation."
else
  # Create the TPU VM with specified parameters
  log "Creating TPU VM with name: $TPU_NAME, type: $TPU_TYPE..."
  
  CREATE_CMD="gcloud compute tpus tpu-vm create \"$TPU_NAME\" \
    --zone=\"$TPU_ZONE\" \
    --project=\"$PROJECT_ID\" \
    --accelerator-type=\"$TPU_TYPE\" \
    --version=\"$TPU_RUNTIME_VERSION\""
  
  # Add service account if specified
  if [[ -n "$SERVICE_ACCOUNT_EMAIL" ]]; then
    CREATE_CMD="$CREATE_CMD --service-account=\"$SERVICE_ACCOUNT_EMAIL\""
  fi
  
  # Execute the command
  eval "$CREATE_CMD"
  
  log 'TPU VM creation completed successfully'
fi

# Install PyTorch and dependencies only if INSTALL_PYTORCH is set to true
if [ "$INSTALL_PYTORCH" = "true" ]; then
  log "Installing PyTorch and dependencies..."
  
  gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --command="
      sudo apt-get update && \
      sudo apt-get install libopenblas-dev libomp5 -y && \
      pip install mkl mkl-include && \
      pip install numpy && \
      pip install torch torch_xla[tpu]~=2.5.0 -f https://storage.googleapis.com/libtpu-releases/index.html && \
      # Handle setuptools version issue if it occurs
      if pip install torch_xla[tpu] -f https://storage.googleapis.com/libtpu-releases/index.html | grep -q 'InvalidRequirement'; then
        pip install setuptools==62.1.0 && \
        pip install torch_xla[tpu] -f https://storage.googleapis.com/libtpu-releases/index.html
      fi
    "
      
  log "PyTorch installation completed"
  
  # Verify PyTorch installation
  log "Verifying PyTorch installation..."
  
  gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --command="PJRT_DEVICE=TPU python3 -c \"import torch_xla.core.xla_model as xm; print('XLA Supported Devices:', xm.get_xla_supported_devices('TPU'))\""
  
  log "PyTorch verification completed"
fi

log "TPU Setup Complete. TPU '$TPU_NAME' is ready for use with PyTorch."