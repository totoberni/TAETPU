#!/bin/bash
# This script creates the TPU VM, sets up Docker permissions,
# configures the TPU environment on the VM (using the entrypoint inside the container),
# and pulls the Docker image.

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

init_script 'TPU Setup'
ENV_FILE="$PROJECT_DIR/source/.env"

# --- Script Variables ---
SKIP_VERIFICATION=false
SKIP_DOCKER_SETUP=false
FORCE_RECREATE=false

# --- Parse Command Line Arguments ---
function show_usage() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Create and configure TPU VM"
  echo ""
  echo "Options:"
  echo "  --skip-verify      Skip TPU environment verification"
  echo "  --skip-docker      Skip Docker setup on the VM"
  echo "  --force-recreate   Force recreation of TPU VM if it exists"
  echo "  -h, --help         Show this help message"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-verify)
      SKIP_VERIFICATION=true
      shift ;;
    --skip-docker)
      SKIP_DOCKER_SETUP=true
      shift ;;
    --force-recreate)
      FORCE_RECREATE=true
      shift ;;
    -h|--help)
      show_usage ;;
    *)
      log_error "Unknown option: $1"
      show_usage ;;
  esac
done

# --- Verify environment variables ---
log "Verifying environment variables..."
"$PROJECT_DIR/src/utils/verify.sh" --env-only || {
  log_error "Environment verification failed. Fix the issues before proceeding."
  exit 1
}

log "Loading environment variables from $ENV_FILE..."
if [[ -f "$ENV_FILE" ]]; then
  source "$ENV_FILE"
  log_success "Environment variables loaded"
else
  log_error "No .env file found at $ENV_FILE"
  exit 1
fi

# Check required variables
check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_TYPE" "TPU_NAME" "TPU_VM_VERSION" || exit 1

# Get additional variables with defaults if not set
TPU_REGION="${TPU_REGION:-$(echo "$TPU_ZONE" | cut -d'-' -f1,2)}"
BUCKET_REGION="${BUCKET_REGION:-$TPU_REGION}"
TPU_DEBUG="${TPU_DEBUG:-false}"

# Display all relevant configuration
display_config "PROJECT_ID" "TPU_REGION" "TPU_ZONE" "TPU_TYPE" "TPU_NAME" "TPU_VM_VERSION" "BUCKET_REGION" "TPU_DEBUG"

setup_auth

log "Configuring Google Cloud project and zone..."
gcloud config set project "$PROJECT_ID"
gcloud config set compute/zone "$TPU_ZONE"
log "Project and zone configured: $PROJECT_ID in $TPU_ZONE"

log "Checking if TPU VM exists: $TPU_NAME"
TPU_EXISTS=false
if gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" &>/dev/null; then
  TPU_EXISTS=true
  log_success "TPU VM exists: $TPU_NAME"
  
  if [[ "$FORCE_RECREATE" == "true" ]]; then
    log "Force recreate flag set. Deleting existing TPU VM..."
    gcloud compute tpus tpu-vm delete "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" --quiet
    TPU_EXISTS=false
    log_success "Existing TPU VM deleted"
  else
    log "Skipping creation."
  fi
fi

if [[ "$TPU_EXISTS" == "false" ]]; then
  log "Creating TPU VM with name: $TPU_NAME, type: $TPU_TYPE, version: $TPU_VM_VERSION..."
  CREATE_CMD="gcloud compute tpus tpu-vm create \"$TPU_NAME\" \
    --zone=\"$TPU_ZONE\" \
    --project=\"$PROJECT_ID\" \
    --accelerator-type=\"$TPU_TYPE\" \
    --version=\"$TPU_VM_VERSION\""
  if [[ -n "$SERVICE_ACCOUNT_EMAIL" ]]; then
    CREATE_CMD="$CREATE_CMD --service-account=\"$SERVICE_ACCOUNT_EMAIL\""
  fi
  eval "$CREATE_CMD"
  if [[ $? -ne 0 ]]; then
    log_error "Failed to create TPU VM"
    exit 1
  fi
  log_success "TPU VM created successfully"
fi

log "Setting up Docker permissions on TPU VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" \
  --command="sudo usermod -aG docker \$USER && echo 'Docker permissions configured. Reconnect for changes to take effect.'" || {
    log_warning "Failed to set up Docker permissions. Please configure them manually if needed."
}

if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON" ]]; then
  log "Copying service account key to TPU VM and configuring authentication..."
  TMP_KEY="/tmp/tpu_service_account_key.json"
  cp "$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON" "$TMP_KEY"
  gcloud compute tpus tpu-vm scp "$TMP_KEY" "$TPU_NAME": --zone="$TPU_ZONE" --project="$PROJECT_ID" || {
    log_warning "Failed to copy service account key to TPU VM."
  }
  gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" \
    --command="gcloud auth activate-service-account --key-file=tpu_service_account_key.json && gcloud auth configure-docker --quiet" || {
    log_warning "Failed to configure authentication on TPU VM."
  }
  rm "$TMP_KEY"
  log "Service account authentication configured on TPU VM"
else
  log "Configuring Docker authentication for GCR on TPU VM..."
  gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" \
    --command="gcloud auth configure-docker --quiet" || {
    log_warning "Failed to configure Docker authentication on TPU VM."
  }
fi

# --- Setup TPU environment on the VM (the entrypoint in the container handles runtime configuration) ---
log_section "Configuring TPU Environment on VM"
VM_SETUP_SCRIPT=$(mktemp)
cat > "$VM_SETUP_SCRIPT" <<EOF
#!/bin/bash
echo "=== Configuring TPU Environment on VM ==="
# Set TPU environment variables with values from .env
export TPU_NAME=${TPU_NAME:-local}
export TPU_LOAD_LIBRARY=${TPU_LOAD_LIBRARY:-0}
export PJRT_DEVICE=${PJRT_DEVICE:-TPU}
export XLA_USE_BF16=${XLA_USE_BF16:-1}
export NEXT_PLUGGABLE_DEVICE_USE_C_API=${NEXT_PLUGGABLE_DEVICE_USE_C_API:-true}
export TF_PLUGGABLE_DEVICE_LIBRARY_PATH=${TF_PLUGGABLE_DEVICE_LIBRARY_PATH:-/lib/libtpu.so}
export TPU_DEBUG=${TPU_DEBUG:-false}

echo "TPU Environment Configuration:"
echo "  TPU_NAME=\$TPU_NAME"
echo "  TPU_LOAD_LIBRARY=\$TPU_LOAD_LIBRARY"
echo "  PJRT_DEVICE=\$PJRT_DEVICE"
echo "  XLA_USE_BF16=\$XLA_USE_BF16"
echo "  NEXT_PLUGGABLE_DEVICE_USE_C_API=\$NEXT_PLUGGABLE_DEVICE_USE_C_API"
echo "  TF_PLUGGABLE_DEVICE_LIBRARY_PATH=\$TF_PLUGGABLE_DEVICE_LIBRARY_PATH"
echo "  TPU_DEBUG=\$TPU_DEBUG"

if [[ ! -f "\$TF_PLUGGABLE_DEVICE_LIBRARY_PATH" ]]; then
  echo "WARNING: TPU driver not found at \$TF_PLUGGABLE_DEVICE_LIBRARY_PATH. Searching..."
  for loc in /lib/libtpu.so /usr/lib/libtpu.so /usr/local/lib/libtpu.so; do
    if [[ -f "\$loc" ]]; then
      echo "Found TPU driver at \$loc"
      export TF_PLUGGABLE_DEVICE_LIBRARY_PATH="\$loc"
      break
    fi
  done
  if [[ ! -f "\$TF_PLUGGABLE_DEVICE_LIBRARY_PATH" ]]; then
    echo "ERROR: TPU driver (libtpu.so) not found"
    exit 1
  fi
fi

if [[ ! -e "/dev/accel0" ]]; then
  echo "WARNING: TPU device (/dev/accel0) not found. Ensure the container runs with --privileged and --device=/dev/accel0"
else
  echo "TPU device (/dev/accel0) is available"
fi

BASHRC_FILE="\$HOME/.bashrc"
if [[ -f "\$BASHRC_FILE" ]]; then
  cp "\$BASHRC_FILE" "\${BASHRC_FILE}.bak"
  echo "Backed up .bashrc to \${BASHRC_FILE}.bak"
fi

if ! grep -q "TPU_ENVIRONMENT_CONFIGURED" "\$BASHRC_FILE" 2>/dev/null; then
  cat >> "\$BASHRC_FILE" << 'INNEREOF'
# TPU environment variables configuration
export TPU_NAME=local
export TPU_LOAD_LIBRARY=0
export PJRT_DEVICE=TPU
export XLA_USE_BF16=1
export NEXT_PLUGGABLE_DEVICE_USE_C_API=true
export TF_PLUGGABLE_DEVICE_LIBRARY_PATH=${TF_PLUGGABLE_DEVICE_LIBRARY_PATH}
export TPU_DEBUG=${TPU_DEBUG}
export TPU_ENVIRONMENT_CONFIGURED=1
INNEREOF
  echo "Added TPU environment variables to .bashrc"
fi

echo "=== TPU Environment Configuration Complete ==="
EOF

log "Copying TPU environment configuration script to VM..."
gcloud compute tpus tpu-vm scp "$VM_SETUP_SCRIPT" "$TPU_NAME":/tmp/tpu_env_setup.sh --zone="$TPU_ZONE" --project="$PROJECT_ID" || {
  log_error "Failed to copy TPU environment setup script to VM"
  rm "$VM_SETUP_SCRIPT"
  exit 1
}

log "Running TPU environment configuration script on VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" --command="chmod +x /tmp/tpu_env_setup.sh && /tmp/tpu_env_setup.sh" || {
  log_error "Failed to run TPU environment configuration script on VM"
  rm "$VM_SETUP_SCRIPT"
  exit 1
}
rm "$VM_SETUP_SCRIPT"

# --- Verify TPU Environment ---
if [[ "$SKIP_VERIFICATION" == "false" ]]; then
  log_section "Verifying TPU Environment"
  source "$PROJECT_DIR/src/utils/verify.sh"
  verify_tpu_environment "$TPU_NAME" "$TPU_ZONE" "$PROJECT_ID" || exit 1
else
  log "Skipping TPU environment verification"
fi

# --- Setup Docker and pull image ---
if [[ "$SKIP_DOCKER_SETUP" == "false" ]]; then
  log_section "Setting up Docker and Pulling Image"
  log "Checking if Docker image exists: gcr.io/$PROJECT_ID/tpu-hello-world:v1"
  if ! gcloud container images describe "gcr.io/$PROJECT_ID/tpu-hello-world:v1" &>/dev/null; then
    log_warning "Docker image not found in GCR. Please run setup_image.sh first."
  else
    log_success "Docker image exists in GCR"
    log "Pulling Docker image on TPU VM..."
    gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" \
      --command="docker pull gcr.io/$PROJECT_ID/tpu-hello-world:v1 || sudo docker pull gcr.io/$PROJECT_ID/tpu-hello-world:v1" || {
        log_warning "Failed to pull Docker image on TPU VM"
      }
  fi
  
  # Find TPU driver path
  DRIVER_PATH=$(check_tpu_driver "$TPU_NAME" "$TPU_ZONE" "$PROJECT_ID")
  if [[ -z "$DRIVER_PATH" ]]; then
    DRIVER_PATH="/lib/libtpu.so"
    log_warning "Could not determine TPU driver path, using default: $DRIVER_PATH"
  else
    log_success "Found TPU driver at: $DRIVER_PATH"
  fi
  
  log "Example Docker command for running your mounted code on TPU:"
  echo "docker run --rm --privileged \\
  --device=/dev/accel0 \\
  -e PJRT_DEVICE=TPU \\
  -e XLA_USE_BF16=1 \\
  -e TPU_NAME=local \\
  -e TPU_DEBUG=${TPU_DEBUG} \\
  -e TF_PLUGGABLE_DEVICE_LIBRARY_PATH=${DRIVER_PATH} \\
  -e NEXT_PLUGGABLE_DEVICE_USE_C_API=true \\
  -v ${DRIVER_PATH}:${DRIVER_PATH} \\
  -v /path/to/your/code:/app/code \\
  gcr.io/$PROJECT_ID/tpu-hello-world:v1 \\
  python3 /app/code/your_script.py"
  
  # Create a helper script on the TPU VM
  TPU_HELPER_SCRIPT=$(mktemp)
  cat > "$TPU_HELPER_SCRIPT" <<EOF
#!/bin/bash
# Helper script for running code on TPU with proper privileges

# Ensure driver path is available
DRIVER_PATH=\${TF_PLUGGABLE_DEVICE_LIBRARY_PATH:-/lib/libtpu.so}
if [[ ! -f "\$DRIVER_PATH" ]]; then
  for loc in /lib/libtpu.so /usr/lib/libtpu.so /usr/local/lib/libtpu.so; do
    if [[ -f "\$loc" ]]; then
      DRIVER_PATH="\$loc"
      break
    fi
  done
fi

# Run with all necessary privileges and mounts
docker run --rm --privileged \\
  --device=/dev/accel0 \\
  -e PJRT_DEVICE=TPU \\
  -e XLA_USE_BF16=1 \\
  -e TPU_NAME=local \\
  -e TPU_DEBUG=${TPU_DEBUG} \\
  -e TF_PLUGGABLE_DEVICE_LIBRARY_PATH=\$DRIVER_PATH \\
  -e NEXT_PLUGGABLE_DEVICE_USE_C_API=true \\
  -v \$DRIVER_PATH:\$DRIVER_PATH \\
  -v \$PWD:/app/code \\
  "\$@"
EOF

  log "Creating TPU helper script on VM..."
  gcloud compute tpus tpu-vm scp "$TPU_HELPER_SCRIPT" "$TPU_NAME":/home/\$(whoami)/run_on_tpu.sh --zone="$TPU_ZONE" --project="$PROJECT_ID" || {
    log_warning "Failed to copy TPU helper script to VM"
  }
  
  gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" \
    --command="chmod +x /home/\$(whoami)/run_on_tpu.sh" || {
      log_warning "Failed to set permissions on TPU helper script"
    }
  
  log_success "Created helper script on TPU VM: run_on_tpu.sh"
  log "Example usage: ./run_on_tpu.sh gcr.io/$PROJECT_ID/tpu-hello-world:v1 python3 /app/code/your_script.py"
  
  rm "$TPU_HELPER_SCRIPT"
else
  log "Skipping Docker setup"
fi

log_success "TPU VM setup complete: $TPU_NAME"
log "You can now connect to your TPU VM using:"
log "gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE --project=$PROJECT_ID"