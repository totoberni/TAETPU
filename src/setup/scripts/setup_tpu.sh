#!/bin/bash
# This script creates the TPU VM, sets up Docker permissions,
# configures the TPU environment on the VM, and pulls the Docker image.
# It now relies on the container’s entrypoint to perform TPU environment configuration.

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

init_script 'TPU Setup'
ENV_FILE="$PROJECT_DIR/source/.env"

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

check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_TYPE" "TPU_NAME" "TPU_VM_VERSION" || exit 1

display_config "PROJECT_ID" "TPU_ZONE" "TPU_TYPE" "TPU_NAME" "TPU_VM_VERSION"

setup_auth

log "Configuring Google Cloud project and zone..."
gcloud config set project "$PROJECT_ID"
gcloud config set compute/zone "$TPU_ZONE"
log "Project and zone configured: $PROJECT_ID in $TPU_ZONE"

log "Checking if TPU VM exists: $TPU_NAME"
if gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" &>/dev/null; then
  log_success "TPU VM exists: $TPU_NAME. Skipping creation."
else
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

# --- Configure TPU environment on the VM ---
log_section "Configuring TPU Environment on VM"
VM_SETUP_SCRIPT=$(mktemp)
cat > "$VM_SETUP_SCRIPT" << 'EOF'
#!/bin/bash
echo "=== Configuring TPU Environment on VM ==="
# Set recommended TPU environment variables.
export TPU_NAME=local
export TPU_LOAD_LIBRARY=0
export PJRT_DEVICE=TPU
export XLA_USE_BF16=1
export NEXT_PLUGGABLE_DEVICE_USE_C_API=true
export TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so

echo "TPU Environment Configuration:"
echo "  TPU_NAME=$TPU_NAME"
echo "  TPU_LOAD_LIBRARY=$TPU_LOAD_LIBRARY"
echo "  PJRT_DEVICE=$PJRT_DEVICE"
echo "  XLA_USE_BF16=$XLA_USE_BF16"
echo "  NEXT_PLUGGABLE_DEVICE_USE_C_API=$NEXT_PLUGGABLE_DEVICE_USE_C_API"
echo "  TF_PLUGGABLE_DEVICE_LIBRARY_PATH=$TF_PLUGGABLE_DEVICE_LIBRARY_PATH"

# Verify TPU driver file
if [[ ! -f "$TF_PLUGGABLE_DEVICE_LIBRARY_PATH" ]]; then
  echo "WARNING: TPU driver not found at $TF_PLUGGABLE_DEVICE_LIBRARY_PATH. Searching..."
  for loc in /lib/libtpu.so /usr/lib/libtpu.so /usr/local/lib/libtpu.so; do
    if [[ -f "$loc" ]]; then
      echo "Found TPU driver at $loc"
      export TF_PLUGGABLE_DEVICE_LIBRARY_PATH="$loc"
      break
    fi
  done
  if [[ ! -f "$TF_PLUGGABLE_DEVICE_LIBRARY_PATH" ]]; then
    echo "ERROR: TPU driver (libtpu.so) not found"
    exit 1
  fi
fi

# Check for TPU device
if [[ ! -e "/dev/accel0" ]]; then
  echo "WARNING: TPU device (/dev/accel0) not found. Ensure the container runs with --privileged and --device=/dev/accel0"
else
  echo "TPU device (/dev/accel0) is available"
fi

# Update .bashrc with TPU environment variables if not already set.
BASHRC_FILE="$HOME/.bashrc"
if [[ -f "$BASHRC_FILE" ]]; then
  cp "$BASHRC_FILE" "${BASHRC_FILE}.bak"
  echo "Backed up .bashrc to ${BASHRC_FILE}.bak"
fi

if ! grep -q "TPU_ENVIRONMENT_CONFIGURED" "$BASHRC_FILE" 2>/dev/null; then
  cat >> "$BASHRC_FILE" << 'INNEREOF'
# TPU environment variables configuration
export TPU_NAME=local
export TPU_LOAD_LIBRARY=0
export PJRT_DEVICE=TPU
export XLA_USE_BF16=1
export NEXT_PLUGGABLE_DEVICE_USE_C_API=true
export TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so
export TPU_ENVIRONMENT_CONFIGURED=1
INNEREOF
  echo "Added TPU environment variables to .bashrc"
fi

echo "=== TPU Environment Configuration Complete ==="
EOF

log "Copying TPU environment configuration script to VM..."
gcloud compute tpus tpu-vm scp "$VM_SETUP_SCRIPT" "$TPU_NAME":/tmp/tpu_env_setup.sh \
  --zone="$TPU_ZONE" --project="$PROJECT_ID" || {
    log_error "Failed to copy TPU environment setup script to VM"
    rm "$VM_SETUP_SCRIPT"
    exit 1
  }

log "Running TPU environment configuration script on VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --project="$PROJECT_ID" \
  --command="chmod +x /tmp/tpu_env_setup.sh && /tmp/tpu_env_setup.sh" || {
    log_error "Failed to run TPU environment configuration script on VM"
    rm "$VM_SETUP_SCRIPT"
    exit 1
  }
rm "$VM_SETUP_SCRIPT"

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
  log "Example Docker command for running your mounted code on TPU:"
  DOCKER_CMD=$(get_docker_cmd "gcr.io/$PROJECT_ID/tpu-hello-world:v1" "python3 /app/code/your_script.py" "/lib/libtpu.so")
  log "$DOCKER_CMD"
else
  log "Skipping Docker setup"
fi

log_success "TPU VM setup complete: $TPU_NAME"
log "You can now connect to your TPU VM using:"
log "gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$TPU_ZONE --project=$PROJECT_ID"
