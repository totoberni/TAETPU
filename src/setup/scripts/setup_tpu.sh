#!/bin/bash

# Get script directory and project root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Import common functions
source "$PROJECT_DIR/src/utils/common.sh"
init_script 'TPU VM Setup'

# Load environment variables
ENV_FILE="$PROJECT_DIR/source/.env"
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" "TPU_NAME" "TPU_TYPE" "TPU_ZONE" "RUNTIME_VERSION" "SERVICE_ACCOUNT_EMAIL" || exit 1

# Set image name from docker-compose
DOCKER_COMPOSE_FILE="$PROJECT_DIR/src/setup/docker/docker-compose.yml"
if [[ -f "$DOCKER_COMPOSE_FILE" ]]; then
    FULL_IMAGE_REF=$(grep -o 'image: eu.gcr.io/${PROJECT_ID}/[^[:space:]]*' "$DOCKER_COMPOSE_FILE" | sed 's/image: //')
    TPU_IMAGE_NAME=$(eval echo "$FULL_IMAGE_REF")
else
    TPU_IMAGE_NAME="eu.gcr.io/${PROJECT_ID}/tae-tpu:v1"
fi

# Container name from docker-compose
CONTAINER_NAME=$(grep -o 'container_name: [^[:space:]]*' "$DOCKER_COMPOSE_FILE" 2>/dev/null | sed 's/container_name: //' || echo "tae-tpu-container")

# Display configuration
log_section "Configuration"
log "Project: $PROJECT_ID"
log "TPU Name: $TPU_NAME"
log "TPU Type: $TPU_TYPE"
log "Zone: $TPU_ZONE"
log "Image: $TPU_IMAGE_NAME"
log "Container: $CONTAINER_NAME"

# Set up authentication
setup_auth

# Set project and zone
gcloud config set project $PROJECT_ID
gcloud config set compute/zone $TPU_ZONE

# Step 1: Create TPU VM if it doesn't exist
log "Checking for TPU VM..."
if ! gcloud compute tpus tpu-vm list --filter="name:$TPU_NAME" --format="value(name)" | grep -q "$TPU_NAME"; then
    log "Creating TPU VM '$TPU_NAME'..."
    gcloud compute tpus tpu-vm create "$TPU_NAME" \
        --zone="$TPU_ZONE" \
        --accelerator-type="$TPU_TYPE" \
        --version="$RUNTIME_VERSION" \
        --service-account="$SERVICE_ACCOUNT_EMAIL" \
        --scopes="https://www.googleapis.com/auth/cloud-platform"
    
    if [ $? -eq 0 ]; then
        log_success "TPU VM created successfully"
    else
        log_error "Failed to create TPU VM"
        exit 1
    fi
else
    log "TPU VM '$TPU_NAME' already exists"
fi

# Step 2: Set up Docker on TPU VM with timeout
log "Setting up Docker on TPU VM..."
timeout_cmd="timeout 60"
if [[ "$(uname)" == "Darwin" ]]; then
    # macOS uses gtimeout from coreutils
    timeout_cmd="gtimeout 60"
fi

# Configure Docker authentication
AUTH_CMD="gcloud auth configure-docker eu.gcr.io --quiet"
if ! gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE --command="$AUTH_CMD" --quiet; then
    log_error "Failed to configure Docker authentication on TPU VM"
    exit 1
fi

# Step 3: Pull the Docker image with proper error handling
log "Pulling Docker image on TPU VM..."
PULL_CMD="sudo docker pull $TPU_IMAGE_NAME"

# First attempt with timeout
if ! gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE --command="$PULL_CMD" --quiet; then
    log_warning "Initial pull attempt failed, trying with explicit credentials..."
    
    # Check if image exists in registry
    if ! gcloud container images describe "$TPU_IMAGE_NAME" &>/dev/null; then
        log_error "Image $TPU_IMAGE_NAME not found in registry. Run setup_image.sh first."
        exit 1
    fi
    
    # Try with explicit login and additional flags
    RETRY_CMD="gcloud auth print-access-token | sudo docker login -u oauth2accesstoken --password-stdin https://eu.gcr.io && sudo docker pull --quiet $TPU_IMAGE_NAME"
    if ! gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE --command="$RETRY_CMD" --quiet; then
        log_error "Failed to pull Docker image after retries"
        exit 1
    fi
fi

log_success "Docker image pulled successfully"

# Step 4: Prepare for container deployment
log "Preparing for container deployment..."

# Create directory structure on TPU VM
PREP_CMD="mkdir -p ~/mount ~/data ~/models ~/logs"
gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE --command="$PREP_CMD" --quiet

# Stop and remove existing container if it exists
CLEANUP_CMD="sudo docker stop $CONTAINER_NAME 2>/dev/null || true; sudo docker rm $CONTAINER_NAME 2>/dev/null || true"
gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE --command="$CLEANUP_CMD" --quiet

# Step 5: Run the container
log "Launching container on TPU VM..."

# Build the docker run command
RUN_CMD="sudo docker run -d --name $CONTAINER_NAME \\
    --privileged \\
    -p 5000:5000 -p 6006:6006 \\
    -v /dev:/dev \\
    -v /lib/libtpu.so:/lib/libtpu.so \\
    -v ~/mount:/app/mount \\
    -v ~/data:/app/data \\
    -v ~/models:/app/models \\
    -v ~/logs:/app/logs \\
    -e PJRT_DEVICE=TPU \\
    -e XLA_USE_BF16=1 \\
    -e PT_XLA_DEBUG_LEVEL=1 \\
    -e NEXT_PLUGGABLE_DEVICE_USE_C_API=true \\
    -e TF_CPP_MIN_LOG_LEVEL=0 \\
    -e XRT_TPU_CONFIG=localservice;0;localhost:51011 \\
    -e TF_XLA_FLAGS=--tf_xla_enable_xla_devices \\
    -e ALLOW_MULTIPLE_LIBTPU_LOAD=1 \\
    -e PROJECT_ID=${PROJECT_ID} \\
    -e BUCKET_NAME=${BUCKET_NAME} \\
    -e BUCKET_DATRAIN=${BUCKET_DATRAIN} \\
    -e BUCKET_TENSORBOARD=${BUCKET_TENSORBOARD} \\
    ${TPU_IMAGE_NAME}"

if ! gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE --command="$RUN_CMD" --quiet; then
    log_error "Failed to start container"
    
    # Get container logs if available
    log "Container logs (if available):"
    gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE --command="sudo docker logs $CONTAINER_NAME 2>&1 || echo 'No logs available'" --quiet
    exit 1
fi

# Step 6: Verify container is running
log "Verifying container status..."
VERIFY_CMD="sudo docker ps -a --filter name=$CONTAINER_NAME --format '{{.Status}}'"
CONTAINER_STATUS=$(gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE --command="$VERIFY_CMD" --quiet)

if [[ "$CONTAINER_STATUS" == *"Up"* ]]; then
    log_success "Container is running successfully"
else
    log_warning "Container may not be running correctly. Status: $CONTAINER_STATUS"
    log "Container logs:"
    gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE --command="sudo docker logs $CONTAINER_NAME" --quiet
fi

# Print success message with access information
log_success "TPU VM setup complete"
log_success "TPU VM address: $TPU_NAME.$TPU_ZONE.tpu.googleusercontent.com"
log_success "Web services (from TPU VM):"
log_success "- TensorBoard: http://localhost:6006"
log_success "- Application: http://localhost:5000"
log_success "SSH access: gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE"
exit 0