#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$SCRIPT_DIR/common.sh"

# --- MAIN SCRIPT ---
log 'Starting comprehensive TPU verification...'

log 'Loading environment variables...'
ENV_FILE="$PROJECT_DIR/source/.env"
source "$ENV_FILE"
log_success 'Environment variables loaded successfully'

# Validate required environment variables
if [[ -z "$PROJECT_ID" || -z "$TPU_ZONE" || -z "$TPU_NAME" ]]; then
  log_error "Required environment variables are missing"
  log_error "Ensure PROJECT_ID, TPU_ZONE, and TPU_NAME are set in .env"
  exit 1
fi

log "Configuration:"
log "- Project ID: $PROJECT_ID"
log "- TPU Zone: $TPU_ZONE"
log "- TPU Name: $TPU_NAME"

# Set up authentication if provided
if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON" ]]; then
  log 'Setting up service account credentials...'
  export GOOGLE_APPLICATION_CREDENTIALS="$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON"
  gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
  log_success 'Service account authentication successful'
fi

# Define a variable for a development directory to mount
DEVELOPMENT_DIR="${PROJECT_DIR}/dev/src"

# Create the development directory if it doesn't exist
if [[ ! -d "$DEVELOPMENT_DIR" ]]; then
  log "Creating development directory for code mounting..."
  mkdir -p "$DEVELOPMENT_DIR"
  log "Created $DEVELOPMENT_DIR"
fi

# Copy the verify.py file to the TPU VM
log "Copying verification script to TPU VM..."
gcloud compute tpus tpu-vm scp "$SCRIPT_DIR/verify.py" "$TPU_NAME":/tmp/verify.py \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all

# Create a temporary script to run on the TPU VM
TEMP_SCRIPT=$(mktemp)
cat > "$TEMP_SCRIPT" << EOF
#!/bin/bash
echo "Running comprehensive TPU verification..."

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

# Make the verification script executable
chmod +x /tmp/verify.py

# Create mount directory if it doesn't exist
mkdir -p /tmp/dev/src

# Try normal docker run first
echo "Trying normal docker run..."
docker run --rm --privileged \\
  --device=/dev/accel0 \\
  -e PJRT_DEVICE=TPU \\
  -e XLA_USE_BF16=1 \\
  -e PYTHONUNBUFFERED=1 \\
  \$DEBUG_OPTS \\
  -v /tmp/verify.py:/app/verify.py \\
  -v /tmp/dev/src:/app/dev/src \\
  gcr.io/$PROJECT_ID/tpu-hello-world:v1 \\
  python /app/verify.py all

# If it failed, try with sudo
if [ \$? -ne 0 ]; then
  echo "Trying with sudo..."
  sudo docker run --rm --privileged \\
    --device=/dev/accel0 \\
    -e PJRT_DEVICE=TPU \\
    -e XLA_USE_BF16=1 \\
    -e PYTHONUNBUFFERED=1 \\
    \$DEBUG_OPTS \\
    -v /tmp/verify.py:/app/verify.py \\
    -v /tmp/dev/src:/app/dev/src \\
    gcr.io/$PROJECT_ID/tpu-hello-world:v1 \\
    python /app/verify.py all
fi
EOF

# Copy the shell script to the TPU VM
log "Copying runner script to TPU VM..."
gcloud compute tpus tpu-vm scp "$TEMP_SCRIPT" "$TPU_NAME":/tmp/verify_setup.sh \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all

# Create a directory for development files on the TPU VM
log "Setting up development directory for code mounting..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all \
    --command="mkdir -p /tmp/dev/src"

# Make it executable and run it
log "Running verification tests inside Docker container on TPU VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all \
    --command="chmod +x /tmp/verify_setup.sh && PROJECT_ID=$PROJECT_ID TPU_DEBUG=${TPU_DEBUG:-false} /tmp/verify_setup.sh"

# Clean up temporary file
rm "$TEMP_SCRIPT"

log "All verification tests complete." 