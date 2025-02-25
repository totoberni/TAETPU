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
# Fix the path to .env - use script directory as reference
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/../source/.env"
log 'Environment variables loaded successfully'

# Validate required environment variables
if [[ -z "$PROJECT_ID" || -z "$TPU_ZONE" || -z "$TPU_TYPE" || -z "$TPU_NAME" ]]; then
  log "ERROR: Required environment variables are missing"
  log "Ensure PROJECT_ID, TPU_ZONE, TPU_TYPE, and TPU_NAME are set in .env"
  exit 1
fi

log "Configuration:"
log "- Project ID: $PROJECT_ID"
log "- TPU Zone: $TPU_ZONE"
log "- TPU Type: $TPU_TYPE"
log "- TPU Name: $TPU_NAME"

# Set up authentication if provided
if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$SCRIPT_DIR/../source/$SERVICE_ACCOUNT_JSON" ]]; then
  log 'Setting up service account credentials...'
  export GOOGLE_APPLICATION_CREDENTIALS="$SCRIPT_DIR/../source/$SERVICE_ACCOUNT_JSON"
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
    --version=\"tpu-ubuntu2204-base\""

  # Add service account if specified
  if [[ -n "$SERVICE_ACCOUNT_EMAIL" ]]; then
    CREATE_CMD="$CREATE_CMD --service-account=\"$SERVICE_ACCOUNT_EMAIL\""
  fi

  # Execute the command
  eval "$CREATE_CMD"

  log 'TPU VM creation completed successfully'
fi

# --- Setup Docker Permissions ---
log "Setting up Docker permissions on TPU VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all \
    --command="sudo usermod -aG docker \$USER && echo 'Docker permissions configured. You may need to reconnect to the VM for changes to take effect.'"

# --- Copy service account key and configure authentication ---
if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$SCRIPT_DIR/../source/$SERVICE_ACCOUNT_JSON" ]]; then
  log "Copying service account key to TPU VM and configuring authentication..."
  
  # Create a temporary copy of the key with a recognizable name
  TMP_KEY="/tmp/tpu_service_account_key.json"
  cp "$SCRIPT_DIR/../source/$SERVICE_ACCOUNT_JSON" "$TMP_KEY"
  
  # Copy the key to the TPU VM
  gcloud compute tpus tpu-vm scp "$TMP_KEY" "$TPU_NAME": \
      --zone="$TPU_ZONE" \
      --project="$PROJECT_ID" \
      --worker=all
  
  # Configure authentication on the TPU VM
  gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
      --zone="$TPU_ZONE" \
      --project="$PROJECT_ID" \
      --worker=all \
      --command="gcloud auth activate-service-account --key-file=tpu_service_account_key.json && gcloud auth configure-docker --quiet"
  
  # Remove the temporary copy
  rm "$TMP_KEY"
  
  log "Service account authentication configured on TPU VM"
else
  # --- Setup Docker Authentication without service account ---
  log "Configuring Docker authentication for Google Container Registry..."
  gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
      --zone="$TPU_ZONE" \
      --project="$PROJECT_ID" \
      --worker=all \
      --command="gcloud auth configure-docker --quiet"
fi

# --- Docker Setup ---
log "Pulling Docker image..."
# Create a temporary script to pull the Docker image with fallback to sudo
TEMP_SCRIPT=$(mktemp)
cat > "$TEMP_SCRIPT" << EOF
#!/bin/bash
echo "Attempting to pull Docker image..."
if docker pull gcr.io/$PROJECT_ID/tpu-hello-world:v1; then
  echo "Docker image pulled successfully."
else
  echo "Failed to pull with regular Docker permissions. Trying with sudo..."
  sudo docker pull gcr.io/$PROJECT_ID/tpu-hello-world:v1
  if [ \$? -eq 0 ]; then
    echo "Docker image pulled successfully with sudo."
  else
    echo "ERROR: Failed to pull Docker image."
    echo "Please check:"
    echo "1. Docker credentials are configured"
    echo "2. Image exists in GCR: gcr.io/$PROJECT_ID/tpu-hello-world:v1"
    echo "3. Service account has correct permissions"
    exit 1
  fi
fi
EOF

# Copy the pull script to the TPU VM
gcloud compute tpus tpu-vm scp "$TEMP_SCRIPT" "$TPU_NAME":/tmp/pull_image.sh \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all

# Make it executable and run it
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all \
    --command="chmod +x /tmp/pull_image.sh && /tmp/pull_image.sh"

# Clean up temporary file
rm "$TEMP_SCRIPT"

log "Docker image setup completed."
log "TPU Setup Complete."