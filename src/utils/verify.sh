#!/bin/bash

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source common logging functions
source "$PROJECT_DIR/src/utils/common_logging.sh"

# Default values
ENV_FILE="$PROJECT_DIR/source/.env"
CHECK_ENV=false
CHECK_TPU=false
CHECK_BUCKET=false
CHECK_IMAGE=false

# Initialize the script
init_script "Verification"

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
  log_section "Environment Variables Verification"
  
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
    # Configure TPU environment variables with sensible defaults
    configure_tpu_env
    return 0
  else
    return 1
  fi
}

# Verify TPU hardware
function verify_tpu() {
  log_section "TPU Hardware Verification"
  
  # Setup authentication
  setup_auth
  
  # Check if TPU VM exists
  if ! verify_tpu_existence "$TPU_NAME" "$TPU_ZONE" "$PROJECT_ID"; then
    log_error "TPU VM $TPU_NAME not found"
    return 1
  fi
  
  # Check TPU VM state
  local tpu_state
  tpu_state=$(verify_tpu_state "$TPU_NAME" "$TPU_ZONE" "$PROJECT_ID")
  if [[ $? -ne 0 ]]; then
    log_error "TPU VM is in $tpu_state state (not READY)"
    return 1
  fi

  # Create TPU count script based on documentation example
  local TPU_COUNT_FILE=$(mktemp)
  cat > "$TPU_COUNT_FILE" << 'EOF'
import tensorflow as tf
print(f"TensorFlow can access {len(tf.config.list_logical_devices('TPU'))} TPU cores")
EOF

  # Copy and run TPU count script
  log "Checking TPU device accessibility..."
  gcloud compute tpus tpu-vm scp "$TPU_COUNT_FILE" "$TPU_NAME":/tmp/tpu_count.py \
    --zone="$TPU_ZONE" --project="$PROJECT_ID" > /dev/null
  
  ssh_with_timeout "export TPU_NAME=local && \
               export PJRT_DEVICE=TPU && \
               export NEXT_PLUGGABLE_DEVICE_USE_C_API=true && \
               export TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so && \
               python3 /tmp/tpu_count.py" 60
  
  local count_result=$?
  if [[ $count_result -ne 0 ]]; then
    log_error "TPU core detection failed. Cannot proceed with computation test."
    rm -f "$TPU_COUNT_FILE"
    return 1
  fi

  # Create TPU computation test script based on documentation example
  local TPU_TEST_FILE=$(mktemp)
  cat > "$TPU_TEST_FILE" << 'EOF'
import tensorflow as tf
print("Tensorflow version " + tf.__version__)

@tf.function
def add_fn(x,y):
  z = x + y
  return z

resolver = tf.distribute.cluster_resolver.TPUClusterResolver()
tf.config.experimental_connect_to_cluster(resolver)
tf.tpu.experimental.initialize_tpu_system(resolver)
strategy = tf.distribute.TPUStrategy(resolver)

x = tf.constant(1.0)
y = tf.constant(1.0)
result = strategy.run(add_fn, args=(x,y))
print(result)
EOF

  # Copy and run test script
  log "Running TPU computation test..."
  gcloud compute tpus tpu-vm scp "$TPU_TEST_FILE" "$TPU_NAME":/tmp/tpu_test.py \
    --zone="$TPU_ZONE" --project="$PROJECT_ID" > /dev/null
  
  ssh_with_timeout "export TPU_NAME=local && \
               export PJRT_DEVICE=TPU && \
               export NEXT_PLUGGABLE_DEVICE_USE_C_API=true && \
               export TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so && \
               python3 /tmp/tpu_test.py" 120
  
  local result=$?
  rm -f "$TPU_TEST_FILE" "$TPU_COUNT_FILE"
  
  if [[ $result -eq 0 ]]; then
    log_success "TPU hardware verification passed"
    return 0
  else
    log_error "TPU computation test failed"
    return 1
  fi
}

# Verify GCS bucket
function verify_bucket() {
  log_section "GCS Bucket Verification"
  
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
  log_section "Docker Image Verification"
  
  # Setup authentication
  setup_auth
  
  local IMAGE_NAME="gcr.io/${PROJECT_ID}/tpu-hello-world:v1"
  
  if ! gcloud container images describe "$IMAGE_NAME" &> /dev/null; then
    log_error "Docker image not found: $IMAGE_NAME"
    log_error "Please run setup_image.sh first to build the image"
    return 1
  fi
  
  log_success "Docker image exists: $IMAGE_NAME"
  
  # Check if we're on the TPU VM to verify actual container TPU access
  if verify_tpu_existence "$TPU_NAME" "$TPU_ZONE" "$PROJECT_ID"; then
    log "Running Docker container with TPU access verification..."
    
    # Create a simple verification script with explicitly hardcoded image name
    local DOCKER_TEST_FILE=$(mktemp)
    cat > "$DOCKER_TEST_FILE" << EOF
#!/bin/bash
FULL_IMAGE_NAME="gcr.io/${PROJECT_ID}/tpu-hello-world:v1"
echo "Using Docker image: \$FULL_IMAGE_NAME"

docker run --rm --privileged \\
  --device=/dev/accel0 \\
  -e PJRT_DEVICE=TPU \\
  -e TPU_NAME=local \\
  -e NEXT_PLUGGABLE_DEVICE_USE_C_API=true \\
  -e TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so \\
  -v /lib/libtpu.so:/lib/libtpu.so \\
  \$FULL_IMAGE_NAME \\
  python -c "import tensorflow as tf; print(f'TensorFlow version: {tf.__version__}'); print(f'TensorFlow can access {len(tf.config.list_logical_devices(\"TPU\"))} TPU cores')"
EOF
    
    # Make it executable
    chmod +x "$DOCKER_TEST_FILE"
    
    # Transfer the PROJECT_ID to the remote VM
    ssh_with_timeout "echo 'export PROJECT_ID=${PROJECT_ID}' > /tmp/project_env.sh" 30
    
    # Copy and run on TPU VM
    gcloud compute tpus tpu-vm scp "$DOCKER_TEST_FILE" "$TPU_NAME":/tmp/verify_docker.sh \
      --zone="$TPU_ZONE" --project="$PROJECT_ID" > /dev/null
    
    ssh_with_timeout "chmod +x /tmp/verify_docker.sh && source /tmp/project_env.sh && /tmp/verify_docker.sh" 120
    
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

log_elapsed_time
exit $EXIT_CODE