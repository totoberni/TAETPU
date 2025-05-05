#!/bin/bash
set -e

# Source environment variables
source $(dirname "$0")/../utils/common.sh

# Initialize
init_script 'TPU VM Setup'

log "Starting TPU VM setup"

# Check authentication and permissions
check_gcloud_auth

# Create TPU VM
log "Creating TPU VM: ${TPU_NAME} (${TPU_TYPE}) in ${TPU_ZONE}"
gcloud compute tpus tpu-vm create ${TPU_NAME} \
  --zone=${TPU_ZONE} \
  --accelerator-type=${TPU_TYPE} \
  --version=${RUNTIME_VERSION} \
  --project=${PROJECT_ID}

# Copy necessary files to TPU VM
log "Copying configuration files to TPU VM"
gcloud compute tpus tpu-vm scp \
  "config/${SERVICE_ACCOUNT_JSON}" \
  "${TPU_NAME}:~/${SERVICE_ACCOUNT_JSON}" \
  --zone=${TPU_ZONE} \
  --project=${PROJECT_ID}

# Copy docker-compose.yml to TPU VM for consistent container setup
gcloud compute tpus tpu-vm scp \
  "infrastructure/docker/docker-compose.yml" \
  "${TPU_NAME}:~/docker-compose.yml" \
  --zone=${TPU_ZONE} \
  --project=${PROJECT_ID}

# Set up Docker on TPU VM
log "Setting up Docker on TPU VM"
gcloud compute tpus tpu-vm ssh ${TPU_NAME} \
  --zone=${TPU_ZONE} \
  --project=${PROJECT_ID} \
  --command="
    set -e
    
    # Authenticate with Google Cloud
    gcloud auth activate-service-account --key-file=~/${SERVICE_ACCOUNT_JSON}
    gcloud auth configure-docker ${DOCKER_REGISTRY} --quiet
    
    # Pull the Docker image
    docker pull ${DOCKER_IMAGE}:${CONTAINER_TAG}
    
    # Create mount directory
    mkdir -p ~/${HOST_MOUNT_DIR#./}
    
    # Set environment variables for docker-compose
    export IMAGE_NAME=${DOCKER_IMAGE}
    export CONTAINER_NAME=${CONTAINER_NAME}
    
    # Simple docker run with minimal flags - container configuration is in the image and docker-compose
    docker run -d \
      --name ${CONTAINER_NAME} \
      --privileged \
      -v ~/${HOST_MOUNT_DIR#./}:${CONTAINER_MOUNT_DIR} \
      ${DOCKER_IMAGE}:${CONTAINER_TAG}
    
    # Verify container is running
    docker ps
  "

log_success "TPU VM setup complete. You can connect using:"
log "gcloud compute tpus tpu-vm ssh ${TPU_NAME} --zone=${TPU_ZONE} --project=${PROJECT_ID}"
exit 0