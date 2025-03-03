#!/bin/bash

# --- DETERMINE SCRIPT AND PROJECT DIRECTORIES ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- IMPORT COMMON FUNCTIONS ---
source "$SCRIPT_DIR/../utils/common_logging.sh"

# --- SCRIPT VARIABLES ---
ENV_FILE="$PROJECT_DIR/../source/.env"
CHECK_INFRASTRUCTURE=false
CHECK_HARDWARE=false
FULL_CHECK=false
REQUIRED_ENV_VARS=("PROJECT_ID" "TPU_ZONE" "TPU_NAME" "TPU_TYPE" "TPU_VM_VERSION" "TF_VERSION" "BUCKET_NAME")

# --- DISPLAY USAGE INFORMATION ---
function show_usage() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Unified verification tool for TPU development environment"
  echo ""
  echo "Options:"
  echo "  --env-only        Verify only environment variables (default)"
  echo "  --check-infra     Also check TPU VM, Docker image and GCS bucket existence"
  echo "  --check-hardware  Also verify TPU hardware and driver access"
  echo "  --full            Run a complete verification including TensorFlow test"
  echo "  -h, --help        Show this help message"
  echo ""
  exit 1
}

# --- PARSE COMMAND LINE ARGUMENTS ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --env-only)
      CHECK_INFRASTRUCTURE=false
      CHECK_HARDWARE=false
      FULL_CHECK=false
      shift
      ;;
    --check-infra)
      CHECK_INFRASTRUCTURE=true
      shift
      ;;
    --check-hardware)
      CHECK_INFRASTRUCTURE=true
      CHECK_HARDWARE=true
      shift
      ;;
    --full)
      CHECK_INFRASTRUCTURE=true
      CHECK_HARDWARE=true
      FULL_CHECK=true
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

# --- INITIALIZATION ---
init_script "TPU Environment Verification"

# --- LOAD ENVIRONMENT VARIABLES ---
log "Loading environment variables from $ENV_FILE..."
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
  log_success "Environment variables loaded"
else
  log_error "No .env file found at $ENV_FILE"
  log "Please create a .env file in source/ directory based on the .env.template"
  exit 1
fi

# --- VERIFY ENVIRONMENT VARIABLES ---
function verify_environment() {
  log_section "Environment Variables Verification"
  
  # Check required environment variables
  log "Checking required environment variables..."
  MISSING_VARS=()
  for var in "${REQUIRED_ENV_VARS[@]}"; do
    if [[ -z "${!var}" ]]; then
      MISSING_VARS+=("$var")
    fi
  done

  if [[ ${#MISSING_VARS[@]} -gt 0 ]]; then
    log_error "Missing required environment variables: ${MISSING_VARS[*]}"
    log "Please set these variables in your .env file"
    return 1
  else
    log_success "All required environment variables are set"
  fi

  # Display current configuration
  log "Current configuration:"
  for var in "${REQUIRED_ENV_VARS[@]}"; do
    log "- $var: ${!var}"
  done

  # Check additional TPU-specific variables 
  log "Checking recommended TPU environment variables..."
  if [[ -z "$PJRT_DEVICE" ]]; then
    log_warning "PJRT_DEVICE not set (recommended: TPU)"
  else
    log "- PJRT_DEVICE: $PJRT_DEVICE"
  fi

  if [[ -z "$NEXT_PLUGGABLE_DEVICE_USE_C_API" ]]; then
    log_warning "NEXT_PLUGGABLE_DEVICE_USE_C_API not set (recommended: true)"
  else
    log "- NEXT_PLUGGABLE_DEVICE_USE_C_API: $NEXT_PLUGGABLE_DEVICE_USE_C_API"
  fi

  if [[ -z "$TF_PLUGGABLE_DEVICE_LIBRARY_PATH" ]]; then
    log_warning "TF_PLUGGABLE_DEVICE_LIBRARY_PATH not set (will use default: /lib/libtpu.so)"
  else
    log "- TF_PLUGGABLE_DEVICE_LIBRARY_PATH: $TF_PLUGGABLE_DEVICE_LIBRARY_PATH"
  fi
  
  return 0
}

# --- VERIFY INFRASTRUCTURE ---
function verify_infrastructure() {
  log_section "Infrastructure Verification"
  
  # Setup GCP Authentication
  setup_auth

  # Verify GCP project
  log "Verifying GCP project: $PROJECT_ID"
  if gcloud projects describe "$PROJECT_ID" &>/dev/null; then
    log_success "GCP project exists and is accessible"
  else
    log_error "GCP project $PROJECT_ID is not accessible"
    return 1
  fi

  # Verify TPU VM (if it exists)
  log "Checking if TPU VM exists: $TPU_NAME"
  tpu_exists=$(verify_tpu_existence "$TPU_NAME" "$TPU_ZONE" "$PROJECT_ID")

  if [[ -n "$tpu_exists" ]]; then
    log_success "TPU VM exists: $TPU_NAME"
    
    # Verify TPU VM state
    tpu_state=$(verify_tpu_state "$TPU_NAME" "$TPU_ZONE" "$PROJECT_ID")
    
    if [[ "$tpu_state" == "READY" ]]; then
      log_success "TPU VM is in READY state"
    else
      log_warning "TPU VM is in $tpu_state state (not READY)"
    fi
  else
    log_warning "TPU VM $TPU_NAME not found (will be created by setup_tpu.sh)"
  fi

  # Verify GCS bucket (if it exists)
  log "Checking if GCS bucket exists: $BUCKET_NAME"
  if gsutil ls -b "gs://$BUCKET_NAME" &>/dev/null; then
    log_success "GCS bucket exists and is accessible"
  else
    log_warning "GCS bucket $BUCKET_NAME not found or not accessible (will need to be created)"
  fi

  # Verify Docker image (if it exists)
  log "Checking if Docker image exists: gcr.io/$PROJECT_ID/tpu-hello-world:v1"
  if gcloud container images describe "gcr.io/$PROJECT_ID/tpu-hello-world:v1" &>/dev/null; then
    log_success "Docker image exists in GCR"
  else
    log_warning "Docker image not found in GCR (will be created by setup_image.sh)"
  fi
  
  return 0
}

# --- VERIFY TPU HARDWARE ---
function verify_hardware() {
  log_section "TPU Hardware Verification"
  
  # Check if TPU VM exists
  tpu_exists=$(verify_tpu_existence "$TPU_NAME" "$TPU_ZONE" "$PROJECT_ID")
  if [[ -z "$tpu_exists" ]]; then
    log_error "TPU VM $TPU_NAME not found"
    log "Run setup_tpu.sh --create to create the TPU VM first"
    return 1
  fi

  # Check TPU VM state
  tpu_state=$(verify_tpu_state "$TPU_NAME" "$TPU_ZONE" "$PROJECT_ID")
  if [[ "$tpu_state" != "READY" ]]; then
    log_error "TPU VM is not in READY state (current state: $tpu_state)"
    log "Wait for the TPU VM to reach READY state before proceeding"
    return 1
  fi

  # Create verification script
  log "Creating TPU hardware verification script..."
  TEMP_SCRIPT=$(mktemp)
  cat > "$TEMP_SCRIPT" << 'EOF'
#!/bin/bash

echo "=== TPU Hardware Verification ==="
echo "Running hardware verification checks..."

# Check environment variables
echo "1. Checking TPU environment variables..."
TPU_NAME=${TPU_NAME:-"unknown"}
TPU_LOAD_LIBRARY=${TPU_LOAD_LIBRARY:-"unknown"}
PJRT_DEVICE=${PJRT_DEVICE:-"unknown"}
TF_PLUGGABLE_DEVICE_LIBRARY_PATH=${TF_PLUGGABLE_DEVICE_LIBRARY_PATH:-"unknown"}
NEXT_PLUGGABLE_DEVICE_USE_C_API=${NEXT_PLUGGABLE_DEVICE_USE_C_API:-"unknown"}

echo "- TPU_NAME=$TPU_NAME"
echo "- TPU_LOAD_LIBRARY=$TPU_LOAD_LIBRARY"
echo "- PJRT_DEVICE=$PJRT_DEVICE"
echo "- TF_PLUGGABLE_DEVICE_LIBRARY_PATH=$TF_PLUGGABLE_DEVICE_LIBRARY_PATH"
echo "- NEXT_PLUGGABLE_DEVICE_USE_C_API=$NEXT_PLUGGABLE_DEVICE_USE_C_API"

# Set recommended values if not set correctly
echo "Setting recommended environment variables..."
export TPU_NAME=local
export TPU_LOAD_LIBRARY=0
export PJRT_DEVICE=TPU
export NEXT_PLUGGABLE_DEVICE_USE_C_API=true

echo "2. Checking TPU driver (libtpu.so)..."
if [[ ! -f "$TF_PLUGGABLE_DEVICE_LIBRARY_PATH" ]]; then
  echo "WARNING: TPU driver not found at $TF_PLUGGABLE_DEVICE_LIBRARY_PATH"
  
  # Search for TPU driver in standard locations
  TPU_DRIVER_LOCATIONS=(
    "/lib/libtpu.so"
    "/usr/lib/libtpu.so"
    "/usr/local/lib/libtpu.so"
  )
  
  for loc in "${TPU_DRIVER_LOCATIONS[@]}"; do
    if [[ -f "$loc" ]]; then
      echo "Found TPU driver at $loc"
      export TF_PLUGGABLE_DEVICE_LIBRARY_PATH="$loc"
      break
    fi
  done
  
  # Final check after search
  if [[ ! -f "$TF_PLUGGABLE_DEVICE_LIBRARY_PATH" ]]; then
    echo "ERROR: Could not find TPU driver (libtpu.so)"
    exit 1
  fi
fi
echo "TPU driver found at $TF_PLUGGABLE_DEVICE_LIBRARY_PATH"

echo "3. Checking TPU device..."
if [[ ! -e "/dev/accel0" ]]; then
  echo "ERROR: TPU device /dev/accel0 not found"
  exit 1
fi
echo "TPU device (/dev/accel0) is available"

# Run additional TensorFlow test if --full is specified
if [[ "$1" == "--full" ]]; then
  echo "4. Running TensorFlow test on TPU..."
  # Create a test script
  mkdir -p /tmp/tpu_test
  cat > /tmp/tpu_test/check_tpu.py << 'PYEOF'
import os
import tensorflow as tf
import sys

print(f"TensorFlow version: {tf.__version__}")
print("Checking for TPU devices...")

try:
    # List TPU devices
    physical_devices = tf.config.list_physical_devices('TPU')
    print(f"Number of TPUs: {len(physical_devices)}")
    
    for device in physical_devices:
        print(f"TPU device: {device}")
    
    if not physical_devices:
        print("ERROR: No TPU devices found")
        sys.exit(1)
    
    # Create a TPU distribution strategy
    print("Creating TPU distribution strategy...")
    strategy = tf.distribute.TPUStrategy()
    print("TPU strategy created successfully")
    
    # Run a simple computation on the TPU
    print("Running simple computation...")
    @tf.function
    def simple_computation():
        a = tf.ones((8, 8)) * 5.0
        b = tf.ones((8, 8)) * 3.0
        return tf.matmul(a, b) + a
    
    result = strategy.run(simple_computation)
    print("Computation result shape:", result.shape)
    print("TPU ACCESS VERIFICATION: SUCCESS")
    sys.exit(0)
    
except Exception as e:
    print(f"ERROR: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYEOF

  # Run the test script
  python3 /tmp/tpu_test/check_tpu.py
  RESULT=$?
  rm -rf /tmp/tpu_test
  
  if [[ $RESULT -ne 0 ]]; then
    echo "ERROR: TensorFlow TPU test failed"
    exit $RESULT
  fi
fi

echo "TPU HARDWARE VERIFICATION: SUCCESS"
exit 0
EOF

  # Copy verification script to TPU VM
  log "Copying verification script to TPU VM..."
  gcloud compute tpus tpu-vm scp "$TEMP_SCRIPT" "$TPU_NAME":/tmp/verify_hardware.sh \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID"

  # Run verification script
  log "Running TPU hardware verification on VM..."
  local cmd="chmod +x /tmp/verify_hardware.sh && /tmp/verify_hardware.sh"
  if [[ "$FULL_CHECK" == "true" ]]; then
    cmd="chmod +x /tmp/verify_hardware.sh && /tmp/verify_hardware.sh --full"
  fi
  
  VERIFICATION_OUTPUT=$(gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --command="$cmd" 2>&1)
  
  VERIFICATION_RESULT=$?
  
  # Display verification output
  echo "$VERIFICATION_OUTPUT"
  
  # Clean up temporary script
  rm "$TEMP_SCRIPT"
  
  # Check verification result
  if [[ $VERIFICATION_RESULT -eq 0 ]]; then
    log_success "TPU hardware verification completed successfully"
    return 0
  else
    log_error "TPU hardware verification failed with exit code $VERIFICATION_RESULT"
    return 1
  fi
}

# --- TPU DRIVER VERIFICATION FUNCTIONS ---
# Function to check for TPU driver
function check_tpu_driver() {
  local tpu_name="$1"
  local tpu_zone="$2"
  local project_id="$3"
  local driver_path="${4:-/lib/libtpu.so}"
  
  log "Checking for TPU driver on VM: $tpu_name..."
  
  # Command to check for TPU driver and find it if not in default location
  local cmd="
    if [[ -f \"$driver_path\" ]]; then
      echo \"TPU driver found at: $driver_path\"
      exit 0
    else
      echo \"TPU driver not found at $driver_path, searching for it...\"
      
      # Search for TPU driver in standard locations
      TPU_DRIVER_LOCATIONS=(
        \"/lib/libtpu.so\"
        \"/usr/lib/libtpu.so\"
        \"/usr/local/lib/libtpu.so\"
      )
      
      for loc in \"\${TPU_DRIVER_LOCATIONS[@]}\"; do
        if [[ -f \"\$loc\" ]]; then
          echo \"Found TPU driver at \$loc\"
          exit 0
        fi
      done
      
      # Last chance: search the whole filesystem
      TPU_DRIVER_LOCATION=\$(find / -name \"libtpu.so\" 2>/dev/null | head -n 1)
      if [[ -n \"\$TPU_DRIVER_LOCATION\" ]]; then
        echo \"Found TPU driver at: \$TPU_DRIVER_LOCATION\"
        exit 0
      else
        echo \"ERROR: Could not find TPU driver (libtpu.so)\"
        exit 1
      fi
    fi
  "
  
  # Execute the command on the TPU VM
  local result=$(gcloud compute tpus tpu-vm ssh "$tpu_name" \
    --zone="$tpu_zone" \
    --project="$project_id" \
    --command="$cmd" 2>/dev/null)
  
  # Check result
  if [[ $? -eq 0 ]]; then
    log_success "$result"
    # Extract the driver path if found
    if [[ "$result" =~ Found\ TPU\ driver\ at:\ (.+) ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    elif [[ "$result" =~ TPU\ driver\ found\ at:\ (.+) ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    else
      # Default path if detection is unclear
      echo "$driver_path"
      return 0
    fi
  else
    log_error "Failed to check TPU driver on VM: $tpu_name"
    log_error "$result"
    return 1
  fi
}

# Function to check for TPU device
function check_tpu_device() {
  local tpu_name="$1"
  local tpu_zone="$2"
  local project_id="$3"
  
  log "Checking for TPU device on VM: $tpu_name..."
  
  # Command to check for TPU device
  local cmd="
    if [[ -e \"/dev/accel0\" ]]; then
      echo \"TPU device (/dev/accel0) is available\"
      exit 0
    else
      echo \"ERROR: TPU device /dev/accel0 not found\"
      exit 1
    fi
  "
  
  # Execute the command on the TPU VM
  local result=$(gcloud compute tpus tpu-vm ssh "$tpu_name" \
    --zone="$tpu_zone" \
    --project="$project_id" \
    --command="$cmd" 2>/dev/null)
  
  # Check result
  if [[ $? -eq 0 ]]; then
    log_success "$result"
    return 0
  else
    log_error "Failed to check TPU device on VM: $tpu_name"
    log_error "$result"
    return 1
  fi
}

# Function to run a quick TensorFlow test on TPU
function quick_tpu_test() {
  local tpu_name="$1"
  local tpu_zone="$2"
  local project_id="$3"
  local driver_path="$4"
  
  log "Running quick TensorFlow TPU test on VM: $tpu_name..."
  
  # Command to run a quick TensorFlow test
  local cmd="
    # Configure environment variables
    export TPU_NAME=local
    export TPU_LOAD_LIBRARY=0
    export PJRT_DEVICE=TPU
    export XLA_USE_BF16=1
    export NEXT_PLUGGABLE_DEVICE_USE_C_API=true
    export TF_PLUGGABLE_DEVICE_LIBRARY_PATH=$driver_path
    
    # Run TensorFlow test
    python3 -c \"
import tensorflow as tf
import sys

print(f'TensorFlow version: {tf.__version__}')
try:
    physical_devices = tf.config.list_physical_devices('TPU')
    print(f'Number of TPUs: {len(physical_devices)}')
    
    if len(physical_devices) > 0:
        print('TPU devices:')
        for device in physical_devices:
            print(f'  - {device}')
        print('TPU check: SUCCESS')
        sys.exit(0)
    else:
        print('ERROR: No TPU devices found')
        sys.exit(1)
except Exception as e:
    print(f'ERROR: {str(e)}')
    sys.exit(1)
\"
  "
  
  # Execute the command on the TPU VM
  local result=$(gcloud compute tpus tpu-vm ssh "$tpu_name" \
    --zone="$tpu_zone" \
    --project="$project_id" \
    --command="$cmd" 2>/dev/null)
  
  # Check result
  if [[ $? -eq 0 ]]; then
    log_success "TensorFlow TPU test successful"
    log "$result"
    return 0
  else
    log_error "TensorFlow TPU test failed"
    log_error "$result"
    return 1
  fi
}

# Function to get the standard Docker command with TPU access
function get_docker_cmd() {
  local image_name="$1"
  local command="$2"
  local driver_path="$3"
  local extra_args="${4:-""}"
  local extra_mounts="${5:-""}"
  
  echo "docker run --rm --privileged \\
    --device=/dev/accel0 \\
    -e PJRT_DEVICE=TPU \\
    -e XLA_USE_BF16=1 \\
    -e PYTHONUNBUFFERED=1 \\
    -e TPU_NAME=local \\
    -e TPU_LOAD_LIBRARY=0 \\
    -e TF_PLUGGABLE_DEVICE_LIBRARY_PATH=$driver_path \\
    -e NEXT_PLUGGABLE_DEVICE_USE_C_API=true \\
    $extra_args \\
    -v $driver_path:$driver_path \\
    $extra_mounts \\
    $image_name \\
    $command"
}

# Comprehensive TPU environment verification function
function verify_tpu_environment() {
  local tpu_name="$1"
  local tpu_zone="$2"
  local project_id="$3"
  local run_tf_test="${4:-false}"
  
  log_section "TPU Environment Verification"
  
  # First verify TPU exists and is in READY state
  local tpu_exists=$(verify_tpu_existence "$tpu_name" "$tpu_zone" "$project_id")
  if [[ -z "$tpu_exists" ]]; then
    log_error "TPU VM $tpu_name not found"
    return 1
  fi
  
  local tpu_state=$(verify_tpu_state "$tpu_name" "$tpu_zone" "$project_id")
  if [[ "$tpu_state" != "READY" ]]; then
    log_error "TPU VM is not in READY state (current state: $tpu_state)"
    return 1
  fi
  
  # Check TPU driver
  local driver_path=$(check_tpu_driver "$tpu_name" "$tpu_zone" "$project_id")
  local driver_check=$?
  
  # Check TPU device
  check_tpu_device "$tpu_name" "$tpu_zone" "$project_id"
  local device_check=$?
  
  # Return if driver or device check failed
  if [[ $driver_check -ne 0 || $device_check -ne 0 ]]; then
    log_error "TPU environment verification failed"
    return 1
  fi
  
  # Run TensorFlow test if requested
  if [[ "$run_tf_test" == "true" ]]; then
    quick_tpu_test "$tpu_name" "$tpu_zone" "$project_id" "$driver_path"
    local tf_test=$?
    
    if [[ $tf_test -ne 0 ]]; then
      log_error "TensorFlow TPU test failed"
      return 1
    fi
  fi
  
  log_success "TPU environment verification completed successfully"
  
  # Output the Docker command example
  log "Example Docker command for TPU:"
  local docker_cmd=$(get_docker_cmd "gcr.io/$project_id/tpu-hello-world:v1" "python3 /app/code/your_script.py" "$driver_path")
  log "$docker_cmd"
  
  return 0
}

# --- RUN VERIFICATIONS ---
verify_environment || exit 1

if [[ "$CHECK_INFRASTRUCTURE" == "true" ]]; then
  verify_infrastructure || exit 1
fi

if [[ "$CHECK_HARDWARE" == "true" ]]; then
  verify_hardware || exit 1
fi

log_success "Verification completed successfully"
log_elapsed_time

if [[ "$CHECK_INFRASTRUCTURE" != "true" ]]; then
  log "Use --check-infra to also verify infrastructure components"
fi

if [[ "$CHECK_HARDWARE" != "true" ]]; then
  log "Use --check-hardware to also verify TPU hardware access"
fi

if [[ "$FULL_CHECK" != "true" ]]; then
  log "Use --full to run a complete verification including TensorFlow test"
fi

exit 0 