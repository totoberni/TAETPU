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

# Copy service account key to TPU VM
log "Copying service account key to TPU VM"
gcloud compute tpus tpu-vm scp \
  "config/${SERVICE_ACCOUNT_JSON}" \
  "${TPU_NAME}:~/${SERVICE_ACCOUNT_JSON}" \
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
    
    # Run the Docker container with minimal flags
    docker run -d \
      --name ${CONTAINER_NAME} \
      --privileged \
      --net=host \
      -e PJRT_DEVICE=${PJRT_DEVICE} \
      -e PROJECT_ID=${PROJECT_ID} \
      -v ~/${HOST_MOUNT_DIR#./}:${CONTAINER_MOUNT_DIR} \
      ${DOCKER_IMAGE}:${CONTAINER_TAG}
    
    # Verify container is running
    docker ps
  "

log_success "TPU VM setup complete. You can connect using:"
log "gcloud compute tpus tpu-vm ssh ${TPU_NAME} --zone=${TPU_ZONE} --project=${PROJECT_ID}"
exit 0