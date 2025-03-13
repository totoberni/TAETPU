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
log "Setting up service account authentication..."
setup_auth

# Set project and zone
gcloud config set project $PROJECT_ID
gcloud config set compute/zone $TPU_ZONE

#################################################
# STEP 1: Check if TPU VM exists and create if not
#################################################
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

#################################################
# STEP 2: Configure Docker and pull the image
#################################################
log "Setting up Docker on TPU VM..."

# Configure Docker authentication - create a temporary script
DOCKER_AUTH_SCRIPT=$(mktemp)
cat > "$DOCKER_AUTH_SCRIPT" << EOF
#!/bin/bash
echo "Configuring Docker authentication..."
gcloud auth configure-docker eu.gcr.io --quiet

# Configure access for service account token
echo "Setting up service account token authentication..."
gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin https://eu.gcr.io
EOF

# Copy and execute the Docker auth script
gcloud compute tpus tpu-vm scp "$DOCKER_AUTH_SCRIPT" "$TPU_NAME:/tmp/docker_auth.sh" --zone="$TPU_ZONE" --quiet
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="chmod +x /tmp/docker_auth.sh && /tmp/docker_auth.sh" --quiet
rm "$DOCKER_AUTH_SCRIPT"

# Create Docker pull script with robust error handling
DOCKER_PULL_SCRIPT=$(mktemp)
cat > "$DOCKER_PULL_SCRIPT" << EOF
#!/bin/bash
echo "Pulling Docker image: $TPU_IMAGE_NAME"

# Check if image exists in registry
echo "Verifying image exists in registry..."
if ! gcloud container images describe "$TPU_IMAGE_NAME" &>/dev/null; then
    echo "ERROR: Image $TPU_IMAGE_NAME not found in registry."
    echo "Please run setup_image.sh first to build and push the Docker image."
    exit 1
fi

# First attempt without sudo
if docker pull $TPU_IMAGE_NAME; then
    echo "Successfully pulled Docker image"
    exit 0
fi

echo "First attempt failed, trying with sudo..."

# Second attempt with sudo
if sudo docker pull $TPU_IMAGE_NAME; then
    echo "Successfully pulled Docker image with sudo"
    exit 0
fi

echo "Direct pulls failed, trying with explicit token authentication..."

# Third attempt with explicit token auth - using access token method that works well with GCR
TOKEN=\$(gcloud auth print-access-token)
if echo "\$TOKEN" | sudo docker login -u oauth2accesstoken --password-stdin https://eu.gcr.io && sudo docker pull $TPU_IMAGE_NAME; then
    echo "Successfully pulled Docker image with token authentication"
    exit 0
fi

echo "All pull attempts failed - please check Docker and GCR access"
exit 1
EOF

# Copy and execute the Docker pull script
log "Pulling Docker image on TPU VM..."
gcloud compute tpus tpu-vm scp "$DOCKER_PULL_SCRIPT" "$TPU_NAME:/tmp/docker_pull.sh" --zone="$TPU_ZONE" --quiet
if ! gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="chmod +x /tmp/docker_pull.sh && /tmp/docker_pull.sh" --quiet; then
    log_error "Failed to pull Docker image after multiple attempts"
    exit 1
fi
rm "$DOCKER_PULL_SCRIPT"

log_success "Docker image pulled successfully"

#################################################
# STEP 3: Prepare and start the container
#################################################
log "Preparing for container deployment..."

# Create directory structure on TPU VM
PREP_CMD="mkdir -p ~/mount ~/data ~/models ~/logs"
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="$PREP_CMD" --quiet

# Stop and remove existing container if it exists
CLEANUP_CMD="sudo docker stop $CONTAINER_NAME 2>/dev/null || true; sudo docker rm $CONTAINER_NAME 2>/dev/null || true"
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="$CLEANUP_CMD" --quiet

# Create a robust container start script
CONTAINER_START_SCRIPT=$(mktemp)
cat > "$CONTAINER_START_SCRIPT" << 'EOF'
#!/bin/bash

TPU_IMAGE_NAME="$1"
CONTAINER_NAME="$2"
PROJECT_ID="$3"
BUCKET_NAME="$4"
BUCKET_DATRAIN="$5"
BUCKET_TENSORBOARD="$6"

echo "Starting container: $CONTAINER_NAME from image: $TPU_IMAGE_NAME"

# Verify TPU device access
if [ ! -e /dev/accel0 ]; then
    echo "WARNING: TPU device /dev/accel0 not found. Container may not function correctly."
fi

# Create the Docker run command with carefully escaped variables
# CRITICAL: Using single quotes around the values of environment variables
# that contain special characters to prevent shell interpretation
CMD="sudo docker run -d --name ${CONTAINER_NAME} \
    --privileged \
    -p 5000:5000 -p 6006:6006 \
    -v /dev:/dev \
    -v /lib/libtpu.so:/lib/libtpu.so \
    -v ~/mount:/app/mount \
    -v ~/data:/app/data \
    -v ~/models:/app/models \
    -v ~/logs:/app/logs \
    -e PJRT_DEVICE=TPU \
    -e XLA_USE_BF16=1 \
    -e PT_XLA_DEBUG_LEVEL=1 \
    -e NEXT_PLUGGABLE_DEVICE_USE_C_API=true \
    -e TF_CPP_MIN_LOG_LEVEL=0 \
    -e XRT_TPU_CONFIG='localservice;0;localhost:51011' \
    -e TF_XLA_FLAGS='--tf_xla_enable_xla_devices' \
    -e ALLOW_MULTIPLE_LIBTPU_LOAD=1 \
    -e PROJECT_ID='${PROJECT_ID}' \
    -e BUCKET_NAME='${BUCKET_NAME}' \
    -e BUCKET_DATRAIN='${BUCKET_DATRAIN}' \
    -e BUCKET_TENSORBOARD='${BUCKET_TENSORBOARD}' \
    ${TPU_IMAGE_NAME}"

echo "Executing: $CMD"
eval "$CMD"

EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
    echo "Failed to start container (exit code: $EXIT_CODE)"
    exit $EXIT_CODE
fi

# Verify container is running
sleep 2
CONTAINER_STATUS=$(sudo docker ps -a --filter name="$CONTAINER_NAME" --format '{{.Status}}')
if [[ "$CONTAINER_STATUS" == *"Up"* ]]; then
    echo "Container is running successfully: $CONTAINER_STATUS"
    exit 0
else
    echo "Container may not be running correctly. Status: $CONTAINER_STATUS"
    sudo docker logs "$CONTAINER_NAME"
    exit 1
fi
EOF

# Copy and execute the container start script
log "Launching container on TPU VM..."
gcloud compute tpus tpu-vm scp "$CONTAINER_START_SCRIPT" "$TPU_NAME:/tmp/start_container.sh" --zone="$TPU_ZONE" --quiet

# Use proper argument quoting to avoid parsing issues in the SSH command
CONTAINER_CMD="chmod +x /tmp/start_container.sh && /tmp/start_container.sh \"$TPU_IMAGE_NAME\" \"$CONTAINER_NAME\" \"$PROJECT_ID\" \"$BUCKET_NAME\" \"$BUCKET_DATRAIN\" \"$BUCKET_TENSORBOARD\""
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="$CONTAINER_CMD" --quiet

if [ $? -ne 0 ]; then
    log_error "Failed to start container"
    
    # Get container logs if available
    log "Container logs (if available):"
    gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="sudo docker logs $CONTAINER_NAME 2>&1 || echo 'No logs available'" --quiet
    exit 1
fi
rm "$CONTAINER_START_SCRIPT"

# Verify container is running
log "Verifying container status..."
VERIFY_CMD="sudo docker ps -a --filter name=$CONTAINER_NAME --format '{{.Status}}'"
CONTAINER_STATUS=$(gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="$VERIFY_CMD" --quiet)

if [[ "$CONTAINER_STATUS" == *"Up"* ]]; then
    log_success "Container is running successfully"
else
    log_warning "Container may not be running correctly. Status: $CONTAINER_STATUS"
    log "Container logs:"
    gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="sudo docker logs $CONTAINER_NAME" --quiet
fi

# Print success message with access information
log_success "TPU VM setup complete"
log_success "TPU VM address: $TPU_NAME.$TPU_ZONE.tpu.googleusercontent.com"
log_success "Web services (from TPU VM):"
log_success "- TensorBoard: http://localhost:6006"
log_success "- Application: http://localhost:5000"
log_success "SSH access: gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE"
exit 0