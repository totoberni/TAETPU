#!/bin/bash

# Enable error handling and command tracing
set -e  # Exit on error
set -x  # Print commands as they are executed

# Function for logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function for error handling
handle_error() {
    local line_no=$1
    local error_code=$2
    log "ERROR: Command failed at line $line_no with exit code $error_code"
    exit $error_code
}

# Set up error trap
trap 'handle_error ${LINENO} $?' ERR

log "Starting TPU setup process..."

# Load environment variables from .env file
log "Loading environment variables..."
source .env
log "Environment variables loaded successfully"

# Set the service account credentials
log "Setting up service account credentials..."
export GOOGLE_APPLICATION_CREDENTIALS="$SERVICE_ACCOUNT_JSON"

# Verify the credentials file exists
if [ ! -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    log "ERROR: Service account JSON file not found at $GOOGLE_APPLICATION_CREDENTIALS"
    log "Please ensure you have copied your service account JSON file to: $(pwd)/$SERVICE_ACCOUNT_JSON"
    exit 1
fi
log "Service account credentials file found"

# Set the project and zone
log "Configuring Google Cloud project and zone..."
gcloud config set project $PROJECT_ID
gcloud config set compute/zone $ZONE
log "Project and zone configured: $PROJECT_ID in $ZONE"

# Authenticate with the service account
log "Authenticating with service account..."
gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
log "Service account authentication successful"

# Create the TPU VM
log "Creating TPU VM with name: $TPU_NAME, type: $TPU_TYPE..."
gcloud compute tpus tpu-vm create $TPU_NAME \
    --zone=$ZONE \
    --accelerator-type=$TPU_TYPE \
    --version=$RUNTIME_VERSION \
    --service-account=$SERVICE_ACCOUNT_EMAIL
log "TPU VM creation completed"

# Create a GCS bucket (if it doesn't already exist)
log "Creating GCS bucket: $BUCKET_NAME..."
if gsutil ls -b gs://$BUCKET_NAME > /dev/null 2>&1; then
    log "Bucket already exists, skipping creation"
else
    gsutil mb -p $PROJECT_ID -l $ZONE gs://$BUCKET_NAME
    log "Bucket created successfully"
fi

# Copy the main.py to the TPU VM
log "Copying main.py to TPU VM..."
gcloud compute tpus tpu-vm scp main.py $TPU_NAME: --zone=$ZONE
log "File transfer completed"

# Connect to the TPU VM via SSH
log "Establishing SSH connection to TPU VM..."
gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$ZONE --command="echo 'SSH connection test'" || {
    log "ERROR: Failed to establish SSH connection"
    exit 1
}
log "SSH connection test successful"

# Install optimum-tpu
log "Installing optimum-tpu package..."
gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$ZONE --command="pip install optimum-tpu -f https://storage.googleapis.com/libtpu-releases/index.html"
log "Package installation completed"

# Set PJRT_DEVICE environment variable
log "Configuring TPU environment variables..."
gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$ZONE --command="export PJRT_DEVICE=TPU && echo \$PJRT_DEVICE" || {
    log "ERROR: Failed to set TPU environment variables"
    exit 1
}
log "Environment variables configured"

# Verify TPU VM is responsive
log "Performing final TPU VM health check..."
if gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$ZONE --command="python3 -c 'print(\"TPU VM is responsive\")'"; then
    log "TPU VM health check passed"
else
    log "ERROR: TPU VM health check failed"
    exit 1
fi

log "TPU Setup Complete. TPU '$TPU_NAME' is ready and verified." 
