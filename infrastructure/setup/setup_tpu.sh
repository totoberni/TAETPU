#!/bin/bash

# Get script directory and project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Import common functions
source "$PROJECT_DIR/infrastructure/utils/common.sh"
init_script 'TPU VM Setup'

# Load environment variables
ENV_FILE="$PROJECT_DIR/config/.env"
load_env_vars "$ENV_FILE"

# Essential environment validation only
check_env_vars "PROJECT_ID" "TPU_NAME" "TPU_ZONE" "TPU_TYPE" "RUNTIME_VERSION" "SERVICE_ACCOUNT_EMAIL" "BUCKET_NAME" || exit 1

# Define image name
TPU_IMAGE_NAME="eu.gcr.io/${PROJECT_ID}/tae-tpu:v1"
CONTAINER_NAME="tae-tpu-container"

# Display configuration
log_section "Configuration"
log "Project: $PROJECT_ID"
log "TPU Name: $TPU_NAME"
log "TPU Type: $TPU_TYPE"
log "Zone: $TPU_ZONE"
log "Bucket: $BUCKET_NAME"
log "Image: $TPU_IMAGE_NAME"
log "Service Account: $SERVICE_ACCOUNT_EMAIL"

# Set up authentication
log_section "Setting up authentication"
setup_auth

# Set project and zone
gcloud config set project $PROJECT_ID
gcloud config set compute/zone $TPU_ZONE


# Create TPU VM if it doesn't exist
log_section "TPU VM Provisioning"
log "Checking for TPU VM..."
if ! gcloud compute tpus tpu-vm list --filter="name:$TPU_NAME" --format="value(name)" | grep -q "$TPU_NAME"; then
    log "Creating TPU VM '$TPU_NAME'..."
    gcloud compute tpus tpu-vm create "$TPU_NAME" \
        --zone="$TPU_ZONE" \
        --accelerator-type="$TPU_TYPE" \
        --version="$RUNTIME_VERSION" \
        --service-account="$SERVICE_ACCOUNT_EMAIL"
    
    if [ $? -ne 0 ]; then
        log_error "Failed to create TPU VM"
        exit 1
    fi
    log_success "TPU VM created successfully"
else
    log "TPU VM '$TPU_NAME' already exists"
fi


# Pull image and set up container
log_section "Container Setup"

# Create a simplified setup script for the TPU VM
TPU_SETUP_SCRIPT=$(mktemp)
cat > "$TPU_SETUP_SCRIPT" << EOF
#!/bin/bash

# Authenticate Docker
gcloud auth configure-docker eu.gcr.io --quiet

# Configure Docker with GCR credentials
TOKEN=\$(gcloud auth print-access-token)
echo "\$TOKEN" | sudo docker login -u oauth2accesstoken --password-stdin https://eu.gcr.io

# Clean up any existing container
sudo docker rm -f $CONTAINER_NAME 2>/dev/null || true

# Pull the Docker image
sudo docker pull $TPU_IMAGE_NAME

# Run the container
sudo docker run -d --name $CONTAINER_NAME \
    --privileged \
    --net=host \
    -p 5000:5000 -p 6006:6006 \
    -v /dev:/dev \
    -v /lib/libtpu.so:/lib/libtpu.so \
    -v /app/mount:/app/mount \
    -e PJRT_DEVICE=TPU \
    -e PROJECT_ID='${PROJECT_ID}' \
    -e BUCKET_NAME='${BUCKET_NAME}' \
    $TPU_IMAGE_NAME
EOF

# Copy and execute the setup script
log "Setting up TPU VM environment..."
gcloud compute tpus tpu-vm scp "$TPU_SETUP_SCRIPT" "$TPU_NAME:/tmp/tpu_setup.sh" --zone="$TPU_ZONE" --force-key-file-overwrite
vmssh "chmod +x /tmp/tpu_setup.sh && /tmp/tpu_setup.sh"
vmssh "rm -f '/tmp/tpu_setup.sh'"

# Display connection information
log_section "Setup Complete"
log_success "TPU VM setup complete"
log_success "TPU VM address: $TPU_NAME.$TPU_ZONE.tpu.googleusercontent.com"
log_success "SSH access: gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE"
exit 0