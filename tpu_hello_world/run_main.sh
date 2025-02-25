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
log 'Starting execution of PyTorch Hello World on TPU...'

log 'Loading environment variables...'
source .env
log 'Environment variables loaded successfully'

# Validate required environment variables
if [[ -z "$PROJECT_ID" || -z "$TPU_ZONE" || -z "$TPU_NAME" ]]; then
  log "ERROR: Required environment variables are missing"
  log "Ensure PROJECT_ID, TPU_ZONE, and TPU_NAME are set in .env"
  exit 1
fi

log "Configuration:"
log "- Project ID: $PROJECT_ID"
log "- TPU Zone: $TPU_ZONE"
log "- TPU Name: $TPU_NAME"

# Set up authentication if provided
if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$SERVICE_ACCOUNT_JSON" ]]; then
  log 'Setting up service account credentials...'
  export GOOGLE_APPLICATION_CREDENTIALS="$(pwd)/$SERVICE_ACCOUNT_JSON"
  gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
  log 'Service account authentication successful'
fi

# Copy the main.py file to the TPU VM
log "Copying main.py to TPU VM..."
gcloud compute tpus tpu-vm scp main.py "$TPU_NAME": \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID"
log "main.py copied successfully"

# Run the main.py script on the TPU VM with proper environment variables
log "Running main.py on TPU VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --command="
      export LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:\$HOME/.local/lib/ 
      export PJRT_DEVICE=TPU 
      export PT_XLA_DEBUG=0 
      export USE_TORCH=ON 
      # Uncomment the following line if needed for specific workloads
      # unset LD_PRELOAD 
      python3 main.py
    "

log "Script execution complete."