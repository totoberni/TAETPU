#!/bin/bash

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Source common logging functions
source "$PROJECT_DIR/src/utils/common_logging.sh"

# Default values
ENV_FILE="$PROJECT_DIR/source/.env"
TPU_ENV_FILE="$PROJECT_DIR/source/tpu.env"
DOCKER_DIR="$PROJECT_DIR/src/setup/docker"
DOCKER_COMPOSE="$DOCKER_DIR/docker-compose.yaml"

# Initialize the script
init_script "TPU VM Setup"

# Load environment variables
load_env_vars "$ENV_FILE" || exit 1

# Load TPU-specific environment variables if they exist
if [[ -f "$TPU_ENV_FILE" ]]; then
  log "Loading TPU-specific environment variables..."
  source "$TPU_ENV_FILE"
  log_success "TPU-specific environment variables loaded"
else
  log_warning "TPU-specific environment file not found: $TPU_ENV_FILE"
  log "Please run setup_image.sh first to create the TPU environment file"
  exit 1
fi

# Verify environment variables
"$PROJECT_DIR/src/utils/verify.sh" --env || exit 1

# Display configuration
log_section "TPU Configuration"
display_config "PROJECT_ID" "TPU_ZONE" "TPU_TYPE" "TPU_NAME" "TPU_VM_VERSION" "TF_VERSION" "MODEL_NAME" "MODEL_DIR"

# Set up authentication
setup_auth

# Check if TPU VM already exists
log "Checking if TPU VM exists: $TPU_NAME"
if verify_tpu_existence "$TPU_NAME" "$TPU_ZONE" "$PROJECT_ID"; then
  log_success "TPU VM already exists: $TPU_NAME"
  
  # Check TPU VM state
  if ! verify_tpu_state "$TPU_NAME" "$TPU_ZONE" "$PROJECT_ID"; then
    log_warning "TPU VM exists but is not in READY state. Please check its status."
  fi
  
  # No need to continue with creation
  log_elapsed_time
  exit 0
fi

# Set Docker image name
IMAGE_NAME="gcr.io/${PROJECT_ID}/tensorflow-tpu:${IMAGE_TAG:-v1}"

# Check if the Docker image exists in GCR before creating the TPU
log "Checking if Docker image exists: $IMAGE_NAME"
if ! gcloud container images describe "$IMAGE_NAME" &>/dev/null; then
  log_error "Docker image not found: $IMAGE_NAME"
  log_error "Please run setup_image.sh first to build and push the image"
  exit 1
fi

log_success "Docker image exists: $IMAGE_NAME"

# If TPU_VM_VERSION is not set or is using an outdated format, use the latest
if [[ -z "$TPU_VM_VERSION" || "$TPU_VM_VERSION" == *-pjrt ]]; then
  log "Using latest TPU VM version compatible with TensorFlow"
  TPU_VM_VERSION="tpu-vm-tf-stable"
  log "TPU_VM_VERSION set to: $TPU_VM_VERSION"
fi

# Create TPU VM with the correct software version
log "Creating TPU VM: $TPU_NAME..."

# Build the command with only essential parameters
CREATE_CMD="gcloud compute tpus tpu-vm create \"$TPU_NAME\" \
  --zone=\"$TPU_ZONE\" \
  --project=\"$PROJECT_ID\" \
  --accelerator-type=\"$TPU_TYPE\" \
  --version=\"$TPU_VM_VERSION\""

# Add service account if specified
if [[ -n "$SERVICE_ACCOUNT_EMAIL" ]]; then
  CREATE_CMD="$CREATE_CMD --service-account=\"$SERVICE_ACCOUNT_EMAIL\""
fi

# Log the command being executed
log "Executing: $CREATE_CMD"

# Execute the command
eval "$CREATE_CMD"

if [[ $? -ne 0 ]]; then
  log_error "Failed to create TPU VM"
  exit 1
fi

log_success "TPU VM created successfully: $TPU_NAME"

# Set TPU environment variables on VM based on Google's documentation
log "Setting TensorFlow TPU environment variables on VM..."
# Read tpu.env file line by line, excluding comments, and build env vars for VM
TPU_ENV_VARS=$(grep -v '^#' "$TPU_ENV_FILE" | sed 's/^/export /' | tr '\n' '\n')
ssh_with_timeout "echo '$TPU_ENV_VARS' >> ~/.bashrc" 60 || {
  log_warning "Failed to set TPU environment variables"
}

# Install Docker Compose if not already installed
log "Checking if Docker Compose is installed on TPU VM..."
if ! ssh_with_timeout "docker-compose --version" 30; then
  log "Installing Docker Compose on TPU VM..."
  ssh_with_timeout "sudo curl -L \"https://github.com/docker/compose/releases/download/v2.20.3/docker-compose-$(uname -s)-$(uname -m)\" -o /usr/local/bin/docker-compose && sudo chmod +x /usr/local/bin/docker-compose" 120 || {
    log_warning "Failed to install Docker Compose. Will use docker run instead."
  }
fi

# Configure Docker permissions
log "Configuring Docker permissions on TPU VM..."
ssh_with_timeout "sudo usermod -aG docker \$USER" 60 || {
  log_warning "Failed to configure Docker permissions"
}

# Configure Docker auth for GCR
log "Configuring Docker authentication for GCR..."
ssh_with_timeout "gcloud auth configure-docker --quiet" 60 || {
  log_warning "Failed to configure Docker authentication for GCR"
}

# Create data directory on TPU VM
log "Creating data directory on TPU VM..."
ssh_with_timeout "mkdir -p ~/data" 30 || {
  log_warning "Failed to create data directory"
}

# Copy docker-compose.yaml and tpu.env to TPU VM
log "Copying Docker Compose file and TPU environment file to TPU VM..."
gcloud compute tpus tpu-vm scp "$DOCKER_COMPOSE" "$TPU_NAME":/tmp/docker-compose.yaml \
  --zone="$TPU_ZONE" --project="$PROJECT_ID" > /dev/null || {
  log_warning "Failed to copy Docker Compose file to TPU VM"
}

gcloud compute tpus tpu-vm scp "$TPU_ENV_FILE" "$TPU_NAME":/tmp/tpu.env \
  --zone="$TPU_ZONE" --project="$PROJECT_ID" > /dev/null || {
  log_warning "Failed to copy TPU environment file to TPU VM"
}

# Pull the Docker image from GCR
log "Pulling Docker image from GCR to TPU VM: $IMAGE_NAME"
ssh_with_timeout "docker pull $IMAGE_NAME" 300 || {
  log_error "Failed to pull Docker image. Check network connectivity and permissions."
  exit 1
}

# Create a startup script for running the container with Docker Compose
log "Creating Docker container startup script..."
DOCKER_STARTUP_SCRIPT=$(mktemp)
cat > "$DOCKER_STARTUP_SCRIPT" << EOF
#!/bin/bash

# Export environment variables
export PROJECT_ID=$PROJECT_ID
export TPU_NAME=local
export IMAGE_TAG=${IMAGE_TAG:-v1}
export MODEL_NAME=$MODEL_NAME
export MODEL_DIR=$MODEL_DIR
export HOME=\$HOME

# Check if Docker Compose is installed
if command -v docker-compose &> /dev/null; then
  echo "Starting container with Docker Compose..."
  cd /tmp
  docker-compose -f docker-compose.yaml --env-file=tpu.env up -d
  echo "Container started with Docker Compose"
else
  echo "Docker Compose not found, using docker run instead..."
  # Docker run command with proper TPU permissions
  docker run -d --name tensorflow-tpu-container \\
    --restart unless-stopped \\
    --privileged \\
    --device=/dev/accel0 \\
    -e TPU_NAME=local \\
    -e PJRT_DEVICE=TPU \\
    -e NEXT_PLUGGABLE_DEVICE_USE_C_API=true \\
    -e TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so \\
    -e XRT_TPU_CONFIG="localservice;0;localhost:51011" \\
    -e TF_XLA_FLAGS=--tf_xla_enable_xla_devices \\
    -e MODEL_NAME=$MODEL_NAME \\
    -e MODEL_DIR=/app/model \\
    -v /lib/libtpu.so:/lib/libtpu.so \\
    -v /usr/share/tpu/:/usr/share/tpu/ \\
    -v \$HOME/data:/app/data \\
    $IMAGE_NAME
  echo "Container started with docker run"
fi

# Wait for container to fully start
sleep 5

# Simple test to verify TPU is working
echo "Testing TPU functionality..."
docker exec tensorflow-tpu-container python -c "
import tensorflow as tf
print('TensorFlow version:', tf.__version__)
print('TPU cores available:', len(tf.config.list_logical_devices('TPU')))
if len(tf.config.list_logical_devices('TPU')) > 0:
    print('TPU test successful!')
    try:
        tpu = tf.distribute.cluster_resolver.TPUClusterResolver()
        print('TPU:', tpu.cluster_spec())
        tf.config.experimental_connect_to_cluster(tpu)
        tf.tpu.experimental.initialize_tpu_system(tpu)
        strategy = tf.distribute.TPUStrategy(tpu)
        print('TPU Strategy initialized with', strategy.num_replicas_in_sync, 'replicas')
    except Exception as e:
        print('Note: TPU strategy initialization error:', e)
"

echo "TensorFlow TPU container started. To access it, run: docker exec -it tensorflow-tpu-container /bin/bash"
EOF

# Upload and run the startup script
log "Uploading Docker startup script to TPU VM..."
gcloud compute tpus tpu-vm scp "$DOCKER_STARTUP_SCRIPT" "$TPU_NAME":/tmp/start_tensorflow_container.sh \
  --zone="$TPU_ZONE" --project="$PROJECT_ID" > /dev/null

log "Making startup script executable..."
ssh_with_timeout "chmod +x /tmp/start_tensorflow_container.sh" 30 || {
  log_warning "Failed to set executable permissions on startup script"
}

# Clean up local temp file
rm -f "$DOCKER_STARTUP_SCRIPT"

# Success message
log_success "TPU VM setup complete: $TPU_NAME"
log_section "Next Steps"
log "Connect to your TPU VM with:"
log "gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE --project=$PROJECT_ID"
log ""
log "On the TPU VM, run the container with:"
log "/tmp/start_tensorflow_container.sh"
log ""
log "To verify TPU functionality, run:"
log "$PROJECT_DIR/src/utils/verify.sh --tpu"
log ""
log "To verify Docker container functionality, run:"
log "$PROJECT_DIR/src/utils/verify.sh --image"

log_elapsed_time
exit 0