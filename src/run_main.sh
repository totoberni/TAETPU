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
# Fix the path to .env - use script directory as reference
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/../source/.env"
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
if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$SCRIPT_DIR/../source/$SERVICE_ACCOUNT_JSON" ]]; then
  log 'Setting up service account credentials...'
  export GOOGLE_APPLICATION_CREDENTIALS="$SCRIPT_DIR/../source/$SERVICE_ACCOUNT_JSON"
  gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
  log 'Service account authentication successful'
fi

# Create a temporary script to run on the TPU VM
TEMP_SCRIPT=$(mktemp)
cat > "$TEMP_SCRIPT" << EOF
#!/bin/bash
echo "Running main.py on TPU..."

# Check TPU health
echo "Checking TPU health..."
if ! ls -la /dev/accel* &>/dev/null; then
  echo "ERROR: No TPU devices found at /dev/accel*"
  echo "Please check if TPU is properly initialized"
  exit 1
fi

# Print TPU firmware version if available
if [ -f /sys/firmware/devicetree/base/model ]; then
  echo "TPU model: \$(cat /sys/firmware/devicetree/base/model)"
fi

# Set debug options
if [[ "$TPU_DEBUG" == "true" ]]; then
  echo "Debug mode enabled - verbose logging"
  DEBUG_OPTS="-e TF_CPP_MIN_LOG_LEVEL=0 -e XLA_FLAGS=--xla_dump_to=/tmp/xla_dump"
else
  DEBUG_OPTS="-e TF_CPP_MIN_LOG_LEVEL=3"
fi

# Try normal docker run first
echo "Trying normal docker run..."
docker run --rm --privileged \\
  --device=/dev/accel0 \\
  -e PJRT_DEVICE=TPU \\
  -e XLA_USE_BF16=1 \\
  -e PYTHONUNBUFFERED=1 \\
  \$DEBUG_OPTS \\
  gcr.io/$PROJECT_ID/tpu-hello-world:v1 python main.py

# If it failed, try with sudo
if [ \$? -ne 0 ]; then
  echo "Trying with sudo..."
  sudo docker run --rm --privileged \\
    --device=/dev/accel0 \\
    -e PJRT_DEVICE=TPU \\
    -e XLA_USE_BF16=1 \\
    -e PYTHONUNBUFFERED=1 \\
    \$DEBUG_OPTS \\
    gcr.io/$PROJECT_ID/tpu-hello-world:v1 python main.py
fi
EOF

# Copy the script to the TPU VM
log "Copying main script to TPU VM..."
gcloud compute tpus tpu-vm scp "$TEMP_SCRIPT" "$TPU_NAME":/tmp/run_main.sh \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all

# Make it executable and run it
log "Running main.py inside Docker container on TPU VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all \
    --command="chmod +x /tmp/run_main.sh && PROJECT_ID=$PROJECT_ID TPU_DEBUG=${TPU_DEBUG:-false} /tmp/run_main.sh"

# Clean up temporary file
rm "$TEMP_SCRIPT"

log "Script execution complete."