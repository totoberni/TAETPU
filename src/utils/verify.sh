#!/bin/bash

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source common logging functions
source "$PROJECT_DIR/src/utils/common_logging.sh"

# Default values
ENV_FILE="$PROJECT_DIR/source/.env"
TPU_ENV_FILE="$PROJECT_DIR/source/tpu.env"
VERIFY_ENV=false
VERIFY_IMAGE=false
VERIFY_TPU=false

# Initialize the script
init_script "Environment Verification"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --env)
      VERIFY_ENV=true
      shift
      ;;
    --image)
      VERIFY_IMAGE=true
      shift
      ;;
    --tpu)
      VERIFY_TPU=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [options]"
      echo ""
      echo "Verify environment and setup"
      echo ""
      echo "Options:"
      echo "  --env       Verify environment variables"
      echo "  --image     Verify Docker image functionality"
      echo "  --tpu       Verify TPU functionality"
      echo "  -h, --help  Show this help message"
      exit 1
      ;;
    *)
      log_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

# If no options specified, verify everything
if [[ "$VERIFY_ENV" == "false" && "$VERIFY_IMAGE" == "false" && "$VERIFY_TPU" == "false" ]]; then
  VERIFY_ENV=true
  VERIFY_IMAGE=true
  VERIFY_TPU=true
fi

# Load environment variables
load_env_vars "$ENV_FILE" || exit 1

# Load TPU-specific environment variables if they exist
if [[ -f "$TPU_ENV_FILE" ]]; then
  log "Loading TPU-specific environment variables..."
  source "$TPU_ENV_FILE"
  log_success "TPU-specific environment variables loaded"
else
  log_warning "TPU-specific environment file not found: $TPU_ENV_FILE"
fi

# Verify environment variables
if [[ "$VERIFY_ENV" == "true" ]]; then
  log_section "Environment Variables Verification"
  
  # Required variables
  REQUIRED_VARS=("PROJECT_ID" "TF_VERSION")
  
  # TPU-specific required variables
  if [[ "$VERIFY_TPU" == "true" ]]; then
    REQUIRED_VARS+=("TPU_ZONE" "TPU_TYPE" "TPU_VM_VERSION" "TPU_NAME")
  fi
  
  # Check all required variables
  MISSING_VARS=0
  for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var}" ]]; then
      log_error "Required variable $var is not set"
      MISSING_VARS=$((MISSING_VARS+1))
    else
      log_success "Variable $var is set: ${!var}"
    fi
  done
  
  if [[ $MISSING_VARS -gt 0 ]]; then
    log_error "Missing $MISSING_VARS required variables. Please check your .env and tpu.env files."
    exit 1
  fi
  
  log_success "All required environment variables are set"
fi

# Verify TPU functionality
if [[ "$VERIFY_TPU" == "true" ]]; then
  log_section "TPU Verification"
  
  # Check if TPU VM exists
  log "Checking if TPU VM exists: $TPU_NAME"
  if ! gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" &>/dev/null; then
    log_error "TPU VM does not exist: $TPU_NAME"
    log_error "Please run setup_tpu.sh first to create the TPU VM"
    exit 1
  fi
  
  log_success "TPU VM exists: $TPU_NAME"
  
  # Check TPU VM state
  TPU_STATE=$(gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" --format="value(state)")
  if [[ "$TPU_STATE" != "READY" ]]; then
    log_error "TPU VM is not in READY state. Current state: $TPU_STATE"
    exit 1
  fi
  
  log_success "TPU VM is in READY state"
  
  # Copy and run the TPU verification script
  log "Copying TPU verification script to TPU VM..."
  gcloud compute tpus tpu-vm scp "$SCRIPT_DIR/verify_tpu.py" "$TPU_NAME":/tmp/verify_tpu.py \
    --zone="$TPU_ZONE" --project="$PROJECT_ID" > /dev/null || {
    log_error "Failed to copy TPU verification script to TPU VM"
    exit 1
  }
  
  log "Running TPU verification script on TPU VM..."
  gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" --project="$PROJECT_ID" \
    --command="chmod +x /tmp/verify_tpu.py && docker exec -it tensorflow-tpu-container python /tmp/verify_tpu.py" || {
    log_error "TPU verification failed"
    exit 1
  }
  
  log_success "TPU verification completed successfully"
fi

# Verify Docker image functionality
if [[ "$VERIFY_IMAGE" == "true" ]]; then
  log_section "Docker Image Verification"
  
  # Set Docker image name
  IMAGE_NAME="gcr.io/${PROJECT_ID}/tensorflow-tpu:${IMAGE_TAG:-v1}"
  
  # Check if the Docker image exists in GCR
  log "Checking if Docker image exists: $IMAGE_NAME"
  if ! gcloud container images describe "$IMAGE_NAME" &>/dev/null; then
    log_error "Docker image not found: $IMAGE_NAME"
    log_error "Please run setup_image.sh first to build and push the image"
    exit 1
  fi
  
  log_success "Docker image exists: $IMAGE_NAME"
  
  # Check if TPU VM exists
  log "Checking if TPU VM exists: $TPU_NAME"
  if ! gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" &>/dev/null; then
    log_error "TPU VM does not exist: $TPU_NAME"
    log_error "Please run setup_tpu.sh first to create the TPU VM"
    exit 1
  fi
  
  # Check if container is running on TPU VM
  log "Checking if container is running on TPU VM..."
  CONTAINER_RUNNING=$(gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" --project="$PROJECT_ID" \
    --command="docker ps -q -f name=tensorflow-tpu-container" 2>/dev/null)
  
  if [[ -z "$CONTAINER_RUNNING" ]]; then
    log_error "Container is not running on TPU VM"
    log_error "Please make sure the container is started with /tmp/start_tensorflow_container.sh"
    exit 1
  fi
  
  log_success "Container is running on TPU VM"
  
  # Run a simple test in the container
  log "Running a simple test in the container..."
  TEST_RESULT=$(gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" --project="$PROJECT_ID" \
    --command="docker exec tensorflow-tpu-container python -c 'import tensorflow as tf; print(\"TensorFlow version:\", tf.__version__); print(\"TPU cores available:\", len(tf.config.list_logical_devices(\"TPU\")))'" 2>/dev/null)
  
  if [[ "$TEST_RESULT" == *"TPU cores available: 0"* ]]; then
    log_error "No TPU cores are available in the container"
    log_error "Please check the container setup"
    exit 1
  fi
  
  log_success "Container test successful"
  log "Test result: $TEST_RESULT"
  
  log_success "Docker image verification completed successfully"
fi

log_success "Verification completed successfully"
log_elapsed_time
exit 0
