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
log 'Starting TPU execution process...'

log 'Loading environment variables...'
source .env
log 'Environment variables loaded successfully'

log 'Setting up service account credentials...'
export GOOGLE_APPLICATION_CREDENTIALS="$(pwd)/$SERVICE_ACCOUNT_JSON"

if [ ! -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    log "ERROR: Service account credentials file not found at: $GOOGLE_APPLICATION_CREDENTIALS"
    exit 1
fi
log 'Service account credentials file found'

log 'Authenticating with service account...'
gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
log 'Service account authentication successful'

# Verify TPU VM exists
log "Verifying TPU VM exists..."
if ! gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$ZONE" --project="$PROJECT_ID" &> /dev/null; then
    log "ERROR: TPU VM '$TPU_NAME' not found. Please run setup_tpu.sh first."
    exit 1
fi
log "TPU VM found successfully"

# Install necessary packages
log "Installing PyTorch/XLA on the TPU VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT_ID" \
    --worker=all \
    --command="pip install torch torch_xla -f https://storage.googleapis.com/libtpu-releases/index.html"
log "PyTorch/XLA installation completed"

# Set the PJRT_DEVICE environment variable
log "Setting PJRT_DEVICE environment variable..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT_ID" \
    --worker=all \
    --command="export PJRT_DEVICE=TPU && echo \$PJRT_DEVICE"
log "Environment variables configured"

# Copy the latest version of main.py to the TPU VM
log "Copying latest version of main.py to TPU VM..."
gcloud compute tpus tpu-vm scp main.py "$TPU_NAME": \
    --zone="$ZONE" \
    --project="$PROJECT_ID" \
    --worker=all
log "File transfer completed"

# Run the main.py script
log "Executing main.py on TPU VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$ZONE" \
    --project="$PROJECT_ID" \
    --worker=all \
    --command="python3 main.py"
log "Script execution completed"

log "TPU execution process completed successfully." 