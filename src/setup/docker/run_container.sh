#!/bin/bash

# Get script directory for proper imports
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$PROJECT_DIR/src/utils/common_logging.sh"
init_script "TPU Container Runner"

# Get project ID from gcloud
PROJECT_ID=$(gcloud config get-value project)
log "Running Docker container from gcr.io/${PROJECT_ID}/tpu-hello-world:v1"

# Run container with TPU access
docker run --privileged --rm \
  -v /dev:/dev \
  -v /lib/libtpu.so:/lib/libtpu.so \
  -p 5000:5000 \
  -p 6006:6006 \
  gcr.io/${PROJECT_ID}/tpu-hello-world:v1

# Check exit status
if [ $? -eq 0 ]; then
  log_success "Container execution completed successfully"
else
  log_error "Container execution failed with error code $?"
fi 