#!/bin/bash
set -e

# Source environment variables
source $(dirname "$0")/../utils/common.sh

log_info "Starting TPU VM setup"

# Check authentication and permissions
check_gcloud_auth

# Create TPU VM
log_info "Creating TPU VM: ${TPU_NAME} (${TPU_TYPE}) in ${TPU_ZONE}"
gcloud compute tpus tpu-vm create ${TPU_NAME} \
  --zone=${TPU_ZONE} \
  --accelerator-type=${TPU_TYPE} \
  --version=${RUNTIME_VERSION} \
  --project=${PROJECT_ID}

# Copy service account key to TPU VM
log_info "Copying service account key to TPU VM"
gcloud compute tpus tpu-vm scp \
  "config/${SERVICE_ACCOUNT_JSON}" \
  "${TPU_NAME}:~/${SERVICE_ACCOUNT_JSON}" \
  --zone=${TPU_ZONE} \
  --project=${PROJECT_ID}

# Set up Docker on TPU VM
log_info "Setting up Docker on TPU VM"
gcloud compute tpus tpu-vm ssh ${TPU_NAME} \
  --zone=${TPU_ZONE} \
  --project=${PROJECT_ID} \
  --command="
    set -e
    
    # Authenticate with Google Cloud
    gcloud auth activate-service-account --key-file=~/${SERVICE_ACCOUNT_JSON}
    gcloud auth configure-docker --quiet
    
    # Pull the Docker image
    docker pull gcr.io/${PROJECT_ID}/taetpu:latest
    
    # Create mount directory
    mkdir -p ~/mount
    
    # Run the Docker container with minimal flags
    docker run -d \
      --name taetpu-container \
      --privileged \
      --net=host \
      -e PJRT_DEVICE=TPU \
      -v ~/mount:/app/mount \
      gcr.io/${PROJECT_ID}/taetpu:latest
    
    # Verify container is running
    docker ps
  "

log_info "TPU VM setup complete. You can connect using:"
log_info "gcloud compute tpus tpu-vm ssh ${TPU_NAME} --zone=${TPU_ZONE} --project=${PROJECT_ID}"
exit 0