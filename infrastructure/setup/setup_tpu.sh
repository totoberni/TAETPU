#!/bin/bash
# TPU VM Setup Script - Creates and configures a TPU VM and Docker container
set -e

# ---- Script Constants and Imports ----
# Get the project directory (2 levels up from this script)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/../.." &> /dev/null && pwd )"
ENV_FILE="$PROJECT_DIR/config/.env"

# Import common utilities
source "$SCRIPT_DIR/../utils/common.sh"

# ---- Functions ----

# Validate environment variables and dependencies
function validate_environment() {
  log "Validating environment..."
  
  # Required environment variables
  check_env_vars "PROJECT_ID" "TPU_NAME" "TPU_ZONE" "TPU_TYPE" "CONTAINER_NAME" \
                "IMAGE_NAME" "SERVICE_ACCOUNT_EMAIL" "RUNTIME_VERSION" || exit 1
  load_env_vars "$ENV_FILE"

  # Set default tag if not defined
  CONTAINER_TAG="${CONTAINER_TAG:-latest}"

  # Display configuration
  log_section "Configuration"
  display_config "PROJECT_ID" "TPU_NAME" "TPU_ZONE" "TPU_TYPE" "CONTAINER_NAME" \
                "IMAGE_NAME" "CONTAINER_TAG" "SERVICE_ACCOUNT_EMAIL" "RUNTIME_VERSION"
  
  # Set up authentication
  setup_auth
}

# Set up TPU VM
function setup_tpu() {
  log_section "TPU VM Setup"
  
  # Check if TPU VM already exists
  if gcloud compute tpus tpu-vm describe "${TPU_NAME}" --zone="${TPU_ZONE}" \
     --project="${PROJECT_ID}" &>/dev/null; then
    log_success "TPU VM '${TPU_NAME}' already exists, skipping creation"
  else
    log "Creating TPU VM: ${TPU_NAME} (${TPU_TYPE}) in ${TPU_ZONE}"
    log "This may take a few minutes..."
    
    gcloud compute tpus tpu-vm create "${TPU_NAME}" \
      --project="${PROJECT_ID}" \
      --zone="${TPU_ZONE}" \
      --accelerator-type="${TPU_TYPE}" \
      --version="${RUNTIME_VERSION}" \
      --service-account="${SERVICE_ACCOUNT_EMAIL}"
      
    log_success "TPU VM created successfully"
  fi
  
  # Copy service account key to TPU VM
  if [ -n "${SERVICE_ACCOUNT_JSON}" ] && [ -f "$PROJECT_DIR/config/${SERVICE_ACCOUNT_JSON}" ]; then
    log "Copying service account key to TPU VM"
    vmscp "$PROJECT_DIR/config/${SERVICE_ACCOUNT_JSON}" "." "0"
  fi
}

# Set up Docker container on TPU VM
function setup_docker() {
  log_section "Docker Container Setup"
  log "Setting up Docker container on TPU VM"
  
  # Set up Docker authentication on TPU VM
  log "Setting up Docker authentication"
  setup_docker_auth || log_warning "Docker authentication failed, but continuing..."
  
  # Prepare environment variables for container
  TPU_ENV_FLAGS="-e PJRT_DEVICE=TPU"
  [ -n "${XRT_TPU_CONFIG}" ] && TPU_ENV_FLAGS+=" -e XRT_TPU_CONFIG=\"${XRT_TPU_CONFIG}\""
  [ -n "${XLA_USE_BF16}" ] && TPU_ENV_FLAGS+=" -e XLA_USE_BF16=${XLA_USE_BF16}"
  [ -n "${XLA_TENSOR_ALLOCATOR_MAXSIZE}" ] && TPU_ENV_FLAGS+=" -e XLA_TENSOR_ALLOCATOR_MAXSIZE=${XLA_TENSOR_ALLOCATOR_MAXSIZE}"
  [ -n "${TPU_NUM_DEVICES}" ] && TPU_ENV_FLAGS+=" -e TPU_NUM_DEVICES=${TPU_NUM_DEVICES}"
  [ -n "${XLA_FLAGS}" ] && TPU_ENV_FLAGS+=" -e XLA_FLAGS=${XLA_FLAGS}"
  
  # Full container image reference
  FULL_IMAGE_NAME="${IMAGE_NAME}:${CONTAINER_TAG}"
  
  # Use vmssh from common.sh to execute commands on TPU VM
  vmssh "
    set -e
    
    # Create mount directory structure
    mkdir -p ~/mount
    
    # Make sure Docker is installed
    if ! command -v docker &> /dev/null; then
      echo 'Docker not found. Installing Docker...'
      sudo apt-get update
      sudo apt-get install -y docker.io
    fi
    
    # Check if container already exists and remove it
    echo 'Checking for existing container...'
    if sudo docker ps -a | grep -q ${CONTAINER_NAME}; then
      echo 'Container with name ${CONTAINER_NAME} already exists, removing it...'
      sudo docker stop ${CONTAINER_NAME} 2>/dev/null || true
      sudo docker rm ${CONTAINER_NAME} 2>/dev/null || true
      echo 'Existing container removed'
    fi
    
    # Pull the Docker image
    echo 'Pulling the Docker image...'
    sudo docker pull ${FULL_IMAGE_NAME}
    
    # Run Docker container with sudo
    echo 'Starting Docker container...'
    sudo docker run -d \
      --name ${CONTAINER_NAME} \
      --privileged \
      --net=host \
      ${TPU_ENV_FLAGS} \
      -v ~/mount:/app/mount \
      -v /usr/share/tpu/:/usr/share/tpu/ \
      -v /lib/libtpu.so:/lib/libtpu.so \
      ${FULL_IMAGE_NAME}
    
    # Verify container is running with sudo
    if sudo docker ps | grep -q ${CONTAINER_NAME}; then
      echo 'Container started successfully'
    else
      echo 'Failed to start container'
      exit 1
    fi
  "
}

# Main function
function main() {
  # Initialize
  init_script 'TPU VM Setup'
  
  # Load environment variables
  load_env_vars "$ENV_FILE"
  
  # Validate environment
  validate_environment
  
  # Setup TPU
  setup_tpu
  
  # Setup Docker
  setup_docker
  
  # Completed
  log_success "TPU VM setup complete. Container is running."
  log_success "Image used: ${IMAGE_NAME}:${CONTAINER_TAG}" 
  log_success "Container name: ${CONTAINER_NAME}"
  log_success "You can now use mount.sh and run.sh to interact with the TPU VM."
  log_elapsed_time
}

# ---- Main Execution ----
main