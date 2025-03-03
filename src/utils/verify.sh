#!/bin/bash

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source common logging functions
source "$PROJECT_DIR/src/utils/common_logging.sh"

# Default values
ENV_FILE="$PROJECT_DIR/source/.env"
CHECK_ENV=false
CHECK_TPU=false
CHECK_BUCKET=false
CHECK_IMAGE=false

# Usage information
function show_usage() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Verify TPU development environment"
  echo ""
  echo "Options:"
  echo "  --env           Verify environment variables"
  echo "  --tpu           Verify TPU hardware"
  echo "  --bucket        Verify GCS bucket"
  echo "  --image         Verify Docker image"
  echo "  -h, --help      Show this help message"
  exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --env)
      CHECK_ENV=true
      shift
      ;;
    --tpu)
      CHECK_TPU=true
      shift
      ;;
    --bucket)
      CHECK_BUCKET=true
      shift
      ;;
    --image)
      CHECK_IMAGE=true
      shift
      ;;
    -h|--help)
      show_usage
      ;;
    *)
      log_error "Unknown option: $1"
      show_usage
      ;;
  esac
done

# If no options provided, check environment by default
if [[ "$CHECK_ENV" == "false" && "$CHECK_TPU" == "false" && "$CHECK_BUCKET" == "false" && "$CHECK_IMAGE" == "false" ]]; then
  CHECK_ENV=true
fi

# Load environment variables
load_env_vars "$ENV_FILE"

# Verify environment variables
function verify_env() {
  log "Verifying environment variables..."
  
  # Required environment variables
  local required_vars=(
    "PROJECT_ID" 
    "TPU_ZONE" 
    "TPU_NAME" 
    "TPU_TYPE" 
    "TPU_VM_VERSION" 
    "TF_VERSION" 
    "BUCKET_NAME"
  )
  
  check_env_vars "${required_vars[@]}"
  if [[ $? -eq 0 ]]; then
    log_success "All required environment variables are set"
    return 0
  else
    return 1
  fi
}

# Verify TPU hardware
function verify_tpu() {
  log "Verifying TPU hardware..."
  
  # Setup authentication
  setup_auth
  
  # Check if TPU VM exists
  if ! gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" &> /dev/null; then
    log_error "TPU VM $TPU_NAME not found"
    return 1
  fi
  
  # Check TPU VM state
  local tpu_state=$(gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" --format="value(state)")
  if [[ "$tpu_state" != "READY" ]]; then
    log_error "TPU VM is in $tpu_state state (not READY)"
    return 1
  fi

  # Create TPU test script
  local TPU_TEST_FILE=$(mktemp)
  cat > "$TPU_TEST_FILE" << 'EOF'
import tensorflow as tf
import sys

# Check TPU cores
print(f"TensorFlow can access {len(tf.config.list_logical_devices('TPU'))} TPU cores")

# Try a basic computation 
try:
    @tf.function
    def add_fn(x, y):
        return x + y
    
    resolver = tf.distribute.cluster_resolver.TPUClusterResolver()
    tf.config.experimental_connect_to_cluster(resolver)
    tf.tpu.experimental.initialize_tpu_system(resolver)
    strategy = tf.distribute.TPUStrategy(resolver)
    
    x = tf.constant(1.0)
    y = tf.constant(1.0)
    result = strategy.run(add_fn, args=(x, y))
    print("TPU computation successful")
    print(result)
    sys.exit(0)
except Exception as e:
    print(f"Error: {str(e)}")
    sys.exit(1)
EOF

  # Copy and run test script
  log "Running TPU verification test..."
  gcloud compute tpus tpu-vm scp "$TPU_TEST_FILE" "$TPU_NAME":/tmp/tpu_test.py \
    --zone="$TPU_ZONE" --project="$PROJECT_ID" > /dev/null
  
  gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" --project="$PROJECT_ID" \
    --command="export TPU_NAME=local && \
               export NEXT_PLUGGABLE_DEVICE_USE_C_API=true && \
               export TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so && \
               python3 /tmp/tpu_test.py"
  
  local result=$?
  rm -f "$TPU_TEST_FILE"
  
  if [[ $result -eq 0 ]]; then
    log_success "TPU hardware verification passed"
    return 0
  else
    log_error "TPU hardware verification failed"
    return 1
  fi
}

# Verify GCS bucket
function verify_bucket() {
  log "Verifying GCS bucket..."
  
  # Setup authentication
  setup_auth
  
  if gsutil ls -b "gs://$BUCKET_NAME" &> /dev/null; then
    log_success "GCS bucket exists: gs://$BUCKET_NAME"
    return 0
  else
    log_error "GCS bucket not found: gs://$BUCKET_NAME"
    return 1
  fi
}

# Verify Docker image
function verify_image() {
  log "Verifying Docker image..."
  
  # Setup authentication
  setup_auth
  
  local IMAGE_NAME="gcr.io/${PROJECT_ID}/tpu-hello-world:v1"
  
  if ! gcloud container images describe "$IMAGE_NAME" &> /dev/null; then
    log_error "Docker image not found: $IMAGE_NAME"
    return 1
  fi
  
  log_success "Docker image exists: $IMAGE_NAME"
  
  # Check if we're on the TPU VM to verify actual container TPU access
  if gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" &> /dev/null; then
    log "Running Docker container with TPU access verification..."
    
    # Create a simple verification script
    local DOCKER_TEST_FILE=$(mktemp)
    cat > "$DOCKER_TEST_FILE" << 'EOF'
#!/bin/bash
docker run --rm --privileged \
  --device=/dev/accel0 \
  -e PJRT_DEVICE=TPU \
  -e XLA_USE_BF16=1 \
  -e TPU_NAME=local \
  -e NEXT_PLUGGABLE_DEVICE_USE_C_API=true \
  -e TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so \
  -v /lib/libtpu.so:/lib/libtpu.so \
  gcr.io/$PROJECT_ID/tpu-hello-world:v1 \
  python -c "
import tensorflow as tf
print(f'TensorFlow {tf.__version__} can access {len(tf.config.list_logical_devices(\"TPU\"))} TPU cores')
"
EOF
    
    # Make it executable
    chmod +x "$DOCKER_TEST_FILE"
    
    # Copy and run on TPU VM
    gcloud compute tpus tpu-vm scp "$DOCKER_TEST_FILE" "$TPU_NAME":/tmp/verify_docker.sh \
      --zone="$TPU_ZONE" --project="$PROJECT_ID" > /dev/null
    
    gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
      --zone="$TPU_ZONE" --project="$PROJECT_ID" \
      --command="chmod +x /tmp/verify_docker.sh && /tmp/verify_docker.sh"
    
    local result=$?
    rm -f "$DOCKER_TEST_FILE"
    
    if [[ $result -eq 0 ]]; then
      log_success "Docker container TPU access verification passed"
    else
      log_error "Docker container TPU access verification failed"
      return 1
    fi
  else
    log_warning "TPU VM not found. Skipping Docker container TPU access verification."
    log_warning "To verify Docker container TPU access, run this script on the TPU VM."
  fi
  
  return 0
}

# Run verifications based on flags
EXIT_CODE=0

if [[ "$CHECK_ENV" == "true" ]]; then
  verify_env
  [[ $? -ne 0 ]] && EXIT_CODE=1
fi

if [[ "$CHECK_TPU" == "true" ]]; then
  verify_tpu
  [[ $? -ne 0 ]] && EXIT_CODE=1
fi

if [[ "$CHECK_BUCKET" == "true" ]]; then
  verify_bucket
  [[ $? -ne 0 ]] && EXIT_CODE=1
fi

if [[ "$CHECK_IMAGE" == "true" ]]; then
  verify_image
  [[ $? -ne 0 ]] && EXIT_CODE=1
fi

exit $EXIT_CODE