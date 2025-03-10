#!/bin/bash
set -e

# Get the directory of this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Load environment variables
source "$PROJECT_DIR/source/.env"

# Function to log messages
log_message() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Check for required environment variables
required_vars=("PROJECT_ID" "TPU_NAME" "SERVICE_ACCOUNT_JSON" "TPU_ZONE")
for var in "${required_vars[@]}"; do
  if [ -z "${!var}" ]; then
    log_message "ERROR: Required environment variable $var is not set"
    exit 1
  fi
done

# Authenticate with Google Cloud
log_message "Authenticating with Google Cloud..."
if [ -f "$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON" ]; then
  gcloud auth activate-service-account --key-file="$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON"
else
  log_message "ERROR: Service account JSON file not found: $SERVICE_ACCOUNT_JSON"
  exit 1
fi

# Set project and zone
gcloud config set project $PROJECT_ID
gcloud config set compute/zone $TPU_ZONE

# Configure Docker to use European Google Container Registry
log_message "Configuring Docker for eu.gcr.io..."
gcloud auth configure-docker eu.gcr.io

# Set paths and variables
TPU_IMAGE_NAME="eu.gcr.io/${PROJECT_ID}/tae-tpu:v1"
DOCKER_DIR="$PROJECT_DIR/src/setup/docker"

# Build the TPU container image
log_message "Building TPU image..."
docker build -t $TPU_IMAGE_NAME -f "$DOCKER_DIR/Dockerfile" "$DOCKER_DIR"

# Push the image to the European GCR
log_message "Pushing image to eu.gcr.io..."
docker push $TPU_IMAGE_NAME

# Configure Docker auth on TPU VM
log_message "Configuring Docker on TPU VM..."
gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE \
  --command="gcloud auth configure-docker eu.gcr.io --quiet"

# Pull image on TPU VM
log_message "Pulling image on TPU VM..."
gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE \
  --command="sudo docker pull $TPU_IMAGE_NAME"

log_message "CI/CD setup completed successfully."
log_message "TPU Image available at: $TPU_IMAGE_NAME"

# Generate startup command for the TPU VM
RUN_CMD="sudo docker run --privileged --rm \\
  -v /dev:/dev \\
  -v /lib/libtpu.so:/lib/libtpu.so \\
  -p 5000:5000 \\
  -p 6006:6006 \\
  ${TPU_IMAGE_NAME}"

log_message "To run the container on TPU VM, use:"
log_message "$RUN_CMD"