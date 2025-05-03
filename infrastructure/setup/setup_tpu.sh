#!/bin/bash

# Script to create a TPU VM and pull the Docker image

# --- Basic setup ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/infrastructure/utils/common.sh"

# Initialize script
init_script "Create TPU VM and Pull Docker Image"

# --- Load environment variables ---
ENV_FILE="$PROJECT_DIR/config/.env"
load_env_vars "$ENV_FILE"

# Check required environment variables
log_section "Checking Required Environment Variables"
required_vars=(
  "PROJECT_ID"
  "TPU_REGION"
  "TPU_ZONE"
  "TPU_NAME"
  "TPU_TYPE"
  "SERVICE_ACCOUNT_EMAIL"
)

check_env_vars "${required_vars[@]}" || exit 1

# Set container variables with defaults if not specified in .env
CONTAINER_NAME="${CONTAINER_NAME:-tae-tpu-container}"
CONTAINER_TAG="${CONTAINER_TAG:-latest}"
IMAGE_NAME="${IMAGE_NAME:-eu.gcr.io/${PROJECT_ID}/tae-tpu:v1}"

log_section "Creating TPU VM in GCP"

# Check if TPU already exists
if gcloud compute tpus tpu-vm list \
     --project="$PROJECT_ID" \
     --zone="$TPU_ZONE" \
     --filter="name:$TPU_NAME" \
     --format="value(name)" | grep -q "$TPU_NAME"; then
  
  log_warning "TPU VM $TPU_NAME already exists."
  
  # Check if the VM is running
  STATUS=$(gcloud compute tpus tpu-vm describe "$TPU_NAME" \
           --zone="$TPU_ZONE" \
           --project="$PROJECT_ID" \
           --format="value(state)")
  
  if [ "$STATUS" != "READY" ]; then
    log_error "TPU VM exists but is not in READY state (current: $STATUS). Please fix or delete the TPU before proceeding."
    exit 1
  fi
  
  log_success "TPU VM $TPU_NAME is already running and in READY state."
else
  # Create TPU VM
  log "Creating TPU VM $TPU_NAME with type $TPU_TYPE in zone $TPU_ZONE..."
  
  gcloud compute tpus tpu-vm create "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --accelerator-type="$TPU_TYPE" \
    --version="$RUNTIME_VERSION" \
    --project="$PROJECT_ID" \
    --service-account="$SERVICE_ACCOUNT_EMAIL" \
    --scopes="https://www.googleapis.com/auth/cloud-platform"
  
  if [ $? -ne 0 ]; then
    log_error "Failed to create TPU VM."
    exit 1
  fi
  
  log_success "TPU VM $TPU_NAME created successfully."
fi

log_section "Configuring Docker on TPU VM"

# Configure Docker credentials on TPU VM
log "Configuring Docker authentication..."

# Create script to execute on TPU VM
TMP_SCRIPT=$(mktemp)
cat > "$TMP_SCRIPT" << EOF
#!/bin/bash
# Configure Docker for GCR access
sudo apt-get update
sudo apt-get install -y docker.io
sudo usermod -aG docker \$USER
sudo systemctl start docker
sudo systemctl enable docker

# Configure Docker to authenticate with GCR
echo "Authenticating with Google Container Registry..."
sudo gcloud auth configure-docker --quiet

# Pull the Docker image
echo "Pulling Docker image: $IMAGE_NAME"
sudo docker pull $IMAGE_NAME

# Create tag alias for local use
echo "Creating alias for image name..."
sudo docker tag $IMAGE_NAME $CONTAINER_NAME:$CONTAINER_TAG

# Set up Docker volumes
echo "Creating Docker volumes..."
sudo docker volume create tae-src
sudo docker volume create tae-datasets
sudo docker volume create tae-models
sudo docker volume create tae-checkpoints
sudo docker volume create tae-logs
sudo docker volume create tae-results

# Create and start the container with TPU access
echo "Creating and starting container..."
sudo docker run -d \\
  --name $CONTAINER_NAME \\
  --privileged \\
  --network=host \\
  -e PJRT_DEVICE=TPU \\
  -e XLA_USE_BF16=1 \\
  -e TPU_NAME=local \\
  -e TPU_LOAD_LIBRARY=0 \\
  -e TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so \\
  -e NEXT_PLUGGABLE_DEVICE_USE_C_API=true \\
  -e PROJECT_ID=$PROJECT_ID \\
  -v /dev:/dev \\
  -v /lib/libtpu.so:/lib/libtpu.so \\
  -v /usr/share/tpu/:/usr/share/tpu/ \\
  -v tae-src:/app/mount \\
  -v tae-datasets:/app/datasets \\
  -v tae-models:/app/models \\
  -v tae-checkpoints:/app/checkpoints \\
  -v tae-logs:/app/logs \\
  -v tae-results:/app/results \\
  $IMAGE_NAME

# Create directory structure inside container
echo "Creating directory structure in container..."
sudo docker exec $CONTAINER_NAME mkdir -p /app/mount/cache/prep
sudo docker exec $CONTAINER_NAME mkdir -p /app/mount/configs
sudo docker exec $CONTAINER_NAME mkdir -p /app/mount/data
sudo docker exec $CONTAINER_NAME mkdir -p /app/mount/datasets/clean/static
sudo docker exec $CONTAINER_NAME mkdir -p /app/mount/datasets/clean/transformer
sudo docker exec $CONTAINER_NAME mkdir -p /app/mount/datasets/raw
sudo docker exec $CONTAINER_NAME mkdir -p /app/mount/models/prep
sudo docker exec $CONTAINER_NAME chmod -R 777 /app/mount

echo "Container setup complete."
EOF

chmod +x "$TMP_SCRIPT"

# Execute the setup script on the TPU VM
log "Executing setup script on TPU VM..."
gcloud compute tpus tpu-vm scp "$TMP_SCRIPT" "$TPU_NAME":~/setup_docker.sh --zone="$TPU_ZONE" --project="$PROJECT_ID"
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" --command="bash ~/setup_docker.sh"

if [ $? -ne 0 ]; then
  log_error "Failed to set up Docker on TPU VM."
  rm "$TMP_SCRIPT"
  exit 1
fi

# Clean up temporary script
rm "$TMP_SCRIPT"

log_success "TPU VM $TPU_NAME is ready with Docker container $CONTAINER_NAME running."
log "You can now use the mount.sh, run.sh, and scrap.sh scripts to manage files and run code on the TPU."

# Make the script executable
chmod +x "$0"
exit 0