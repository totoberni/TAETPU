#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

# --- MAIN SCRIPT ---
init_script 'TPU VM setup'
ENV_FILE="$PROJECT_DIR/source/.env"
TPU_ENV_FILE="$PROJECT_DIR/source/tpu.env"

# Load environment variables
log "Loading general environment variables from .env..."
load_env_vars "$ENV_FILE"

# Always load TPU-specific environment variables
log "Loading TPU-specific environment variables from tpu.env..."
if [ -f "$TPU_ENV_FILE" ]; then
    source "$TPU_ENV_FILE"
    log_success "TPU environment variables loaded successfully"
else
    log_error "TPU environment file not found at $TPU_ENV_FILE"
    log_error "This file is required for TPU configuration"
    exit 1
fi

# Validate required environment variables
check_env_vars "PROJECT_ID" "TPU_NAME" "TPU_TYPE" "TPU_ZONE" "RUNTIME_VERSION" "SERVICE_ACCOUNT_JSON" || exit 1

# Display configuration
display_config "PROJECT_ID" "TPU_NAME" "TPU_TYPE" "TPU_ZONE" "RUNTIME_VERSION"

# Display TPU-specific configuration
log "TPU Environment Configuration:"
display_config "PJRT_DEVICE" "XLA_USE_BF16" "PT_XLA_DEBUG_LEVEL" "TF_PLUGGABLE_DEVICE_LIBRARY_PATH"

# Verify the credentials file exists
if [ ! -f "$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON" ]; then
    log_error "Error: Service account JSON file not found at $PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON"
    exit 1
fi

# Set up authentication
setup_auth

# Set the project and zone
log "Setting project to $PROJECT_ID and zone to $TPU_ZONE..."
gcloud config set project $PROJECT_ID
gcloud config set compute/zone $TPU_ZONE

# Check if TPU already exists
log "Checking if TPU '$TPU_NAME' already exists..."
if gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" &> /dev/null; then
    log_warning "TPU '$TPU_NAME' already exists. Skipping creation."
else
    # Create the TPU VM with appropriate parameters
    log "Creating TPU VM '$TPU_NAME'..."
    gcloud compute tpus tpu-vm create "$TPU_NAME" \
        --zone="$TPU_ZONE" \
        --accelerator-type="$TPU_TYPE" \
        --version="$RUNTIME_VERSION" \
        --network="default" \
        --service-account="$SERVICE_ACCOUNT_EMAIL" \
        --scopes="https://www.googleapis.com/auth/cloud-platform" \
        --metadata="install-nvidia-driver=True"
    
    log_success "TPU VM '$TPU_NAME' created successfully."
fi

# Connect to the TPU VM via SSH to install packages
log "Installing packages on TPU VM..."

# Install optimum-tpu
log "Installing optimum-tpu package..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="pip install optimum-tpu -f https://storage.googleapis.com/libtpu-releases/index.html"

# Transfer tpu.env to the TPU VM
log "Transferring TPU environment configuration..."
gcloud compute tpus tpu-vm scp "$TPU_ENV_FILE" "$TPU_NAME:~/tpu.env" --zone="$TPU_ZONE"

# Set ENV variables on the TPU VM
log "Setting environment variables on TPU VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="cat ~/tpu.env >> ~/.bashrc && rm ~/tpu.env"
log_success "TPU environment variables configured on TPU VM"

# Discover TPU driver location
log "Discovering TPU driver location..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="find / -name libtpu.so 2>/dev/null || echo 'TPU driver not found'"

# Pull the Docker image if it exists
log "Pulling Docker image to TPU VM..."
if gcloud container images describe "gcr.io/${PROJECT_ID}/tpu-hello-world:v1" &> /dev/null; then
    log "Found Docker image, pulling to TPU VM..."
    gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="docker pull gcr.io/${PROJECT_ID}/tpu-hello-world:v1"
    
    # Create a sample run script with --privileged flag
    log "Creating a sample Docker run script with --privileged flag..."
    gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="echo '#!/bin/bash
# Sample script to run the Docker container with TPU access
docker run --privileged --rm \\
  -e PJRT_DEVICE=TPU \\
  -e $(grep -v \"^#\" ~/tpu.env | xargs | sed \"s/ / -e /g\") \\
  -v /dev:/dev \\
  -v /lib/libtpu.so:/lib/libtpu.so \\
  -p 5000:5000 \\
  -p 6006:6006 \\
  gcr.io/${PROJECT_ID}/tpu-hello-world:v1' > ~/run_container.sh && chmod +x ~/run_container.sh"
    
    log_success "Docker image pulled to TPU VM successfully."
    log_success "Sample run script created at ~/run_container.sh"
else
    log_warning "Docker image gcr.io/${PROJECT_ID}/tpu-hello-world:v1 not found. Skipping pull."
    log_warning "You may need to run setup_image.sh first to build and push the Docker image."
fi

log_success "TPU Setup Complete. TPU '$TPU_NAME' is ready." 