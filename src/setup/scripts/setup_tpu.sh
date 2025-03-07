#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

# --- MAIN SCRIPT ---
init_script 'TPU VM setup'
ENV_FILE="$PROJECT_DIR/source/.env"
TPU_ENV_FILE="$PROJECT_DIR/source/tpu.env"

# Load environment variables
log "Loading general environment variables from .env..."
load_env_vars "$ENV_FILE"

# Always load TPU-specific environment variables
log "Loading TPU-specific environment variables from tpu.env..."
if [ -f "$TPU_ENV_FILE" ]; then
    source "$TPU_ENV_FILE"
    log_success "TPU environment variables loaded successfully"
else
    log_error "TPU environment file not found at $TPU_ENV_FILE"
    log_error "This file is required for TPU configuration"
    exit 1
fi

# Validate required environment variables
check_env_vars "PROJECT_ID" "TPU_NAME" "TPU_TYPE" "TPU_ZONE" "RUNTIME_VERSION" "SERVICE_ACCOUNT_JSON" || exit 1

# Display configuration
display_config "PROJECT_ID" "TPU_NAME" "TPU_TYPE" "TPU_ZONE" "RUNTIME_VERSION"

# Display TPU-specific configuration
log "TPU Environment Configuration:"
display_config "PJRT_DEVICE" "XLA_USE_BF16" "PT_XLA_DEBUG_LEVEL" "TF_PLUGGABLE_DEVICE_LIBRARY_PATH"

# Verify the credentials file exists
if [ ! -f "$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON" ]; then
    log_error "Error: Service account JSON file not found at $PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON"
    exit 1
fi

# Set up authentication
setup_auth

# Set the project and zone
log "Setting project to $PROJECT_ID and zone to $TPU_ZONE..."
gcloud config set project $PROJECT_ID
gcloud config set compute/zone $TPU_ZONE

# Check if TPU already exists
log "Checking if TPU '$TPU_NAME' already exists..."
if gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" &> /dev/null; then
    log_warning "TPU '$TPU_NAME' already exists. Skipping creation."
else
    # Create the TPU VM with appropriate parameters
    log "Creating TPU VM '$TPU_NAME'..."
    gcloud compute tpus tpu-vm create "$TPU_NAME" \
        --zone="$TPU_ZONE" \
        --accelerator-type="$TPU_TYPE" \
        --version="$RUNTIME_VERSION" \
        --network="default" \
        --service-account="$SERVICE_ACCOUNT_EMAIL" \
        --scopes="https://www.googleapis.com/auth/cloud-platform" \
        --metadata="install-nvidia-driver=True"
    
    log_success "TPU VM '$TPU_NAME' created successfully."
fi

# Connect to the TPU VM via SSH to install packages
log "Installing packages on TPU VM..."

# Install optimum-tpu
log "Installing optimum-tpu package..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="pip install optimum-tpu -f https://storage.googleapis.com/libtpu-releases/index.html"

# --- Set up Docker permissions ---
log "Setting up Docker permissions on TPU VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="sudo usermod -aG docker \$USER"
log_success "Docker permissions configured. You may need to reconnect to the VM for changes to take effect."

# --- Copy service account credentials to the TPU VM - FIXED APPROACH ---
log "Copying service account credentials to TPU VM..."
TMP_KEY="/tmp/tpu_service_account_key.json"
cp "$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON" "$TMP_KEY"

# Use base64 encoding to avoid file path issues
if command -v base64 &> /dev/null; then
    # Create a script to decode and save the service account key
    DECODE_SCRIPT=$(mktemp)
    cat > "$DECODE_SCRIPT" << 'EOF'
#!/bin/bash
# Decode base64 input and save to service-account-key.json
base64 -d > $HOME/service-account-key.json
EOF

    # Encode service account key to base64
    log "Encoding service account key for secure transfer..."
    BASE64_CONTENT=$(base64 -w 0 "$TMP_KEY")
    
    # Transfer decode script to TPU VM
    gcloud compute tpus tpu-vm scp "$DECODE_SCRIPT" "$TPU_NAME:/tmp/decode_key.sh" --zone="$TPU_ZONE"
    
    # Execute script with encoded content as input
    log "Transferring service account key to TPU VM..."
    echo "$BASE64_CONTENT" | gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="chmod +x /tmp/decode_key.sh && /tmp/decode_key.sh"
    
    # Clean up
    rm "$DECODE_SCRIPT"
else
    # Alternative approach: Using native gcloud command without ~ expansion
    log "Attempting direct file transfer..."
    # First ensure the target directory exists
    gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="mkdir -p /home/\$(whoami)/"
    
    # Then transfer the file with an explicit path
    gcloud compute tpus tpu-vm scp "$TMP_KEY" "$TPU_NAME:/home/\$(whoami)/service-account-key.json" --zone="$TPU_ZONE"
fi

rm "$TMP_KEY"  # Clean up temporary file

# Configure authentication on the TPU VM (using explicit home directory path)
log "Configuring Docker authentication on TPU VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="gcloud auth activate-service-account --key-file=\"\$HOME/service-account-key.json\""
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="gcloud auth configure-docker --quiet"
log_success "GCR authentication configured on TPU VM"

# Fixed environment variable transfer - create the TPU environment file directly on the VM
log "Creating TPU environment file directly on the VM..."
# Create a string with all environment variables to set in the VM
TPU_ENV_CONTENT=""
while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and comments
    if [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]]; then
        TPU_ENV_CONTENT+="$line"$'\n'
    fi
done < "$TPU_ENV_FILE"

# Add the environment variables to the VM (using explicit $HOME path)
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="cat > \"\$HOME/tpu.env\" << 'EOF'
$TPU_ENV_CONTENT
EOF"

log "Setting environment variables on TPU VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="cat \"\$HOME/tpu.env\" >> \"\$HOME/.bashrc\" && echo 'export PATH=\$PATH:\$HOME/.local/bin' >> \"\$HOME/.bashrc\""
log_success "TPU environment variables configured on TPU VM"

# Create a robust script to pull the Docker image with multiple fallbacks - FIXED APPROACH
log "Setting up Docker image pull script..."

# Create the pull script content directly on the VM using a heredoc through SSH
log "Creating Docker pull script directly on the TPU VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="cat > \"\$HOME/pull_docker_image.sh\" << 'EOF'
#!/bin/bash

PROJECT_ID=\$(gcloud config get-value project)
IMAGE_NAME=\"gcr.io/\${PROJECT_ID}/tpu-hello-world:v1\"

echo \"Attempting to pull Docker image: \${IMAGE_NAME}\"

# Try first with regular user
if docker pull \${IMAGE_NAME}; then
    echo \"Successfully pulled Docker image with regular permissions.\"
    exit 0
fi

echo \"Regular docker pull failed. Trying with sudo...\"

# Try with sudo
if sudo docker pull \${IMAGE_NAME}; then
    echo \"Successfully pulled Docker image with sudo.\"
    exit 0
fi

echo \"Docker pull attempts failed. Checking authentication...\"

# Try re-authenticating and then pulling
echo \"Re-authenticating with gcloud...\"
gcloud auth configure-docker --quiet

if docker pull \${IMAGE_NAME}; then
    echo \"Successfully pulled Docker image after re-authentication.\"
    exit 0
fi

# One final attempt with sudo after re-authentication
if sudo docker pull \${IMAGE_NAME}; then
    echo \"Successfully pulled Docker image with sudo after re-authentication.\"
    exit 0
fi

echo \"ERROR: All attempts to pull the Docker image failed.\"
echo \"Please check:\"
echo \"1. The image exists in Container Registry at: \${IMAGE_NAME}\"
echo \"2. Service account has necessary permissions\"
echo \"3. Project ID is correct: \${PROJECT_ID}\"
exit 1
EOF
chmod +x \"\$HOME/pull_docker_image.sh\""

# Make the script executable and run it
log "Pulling Docker image on TPU VM (this may take a few minutes)..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="\$HOME/pull_docker_image.sh"

# Create a sample run script with --privileged flag and sudo - FIXED APPROACH
log "Creating a sample Docker run script with --privileged flag..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="cat > \"\$HOME/run_container.sh\" << 'EOF'
#!/bin/bash
# Sample script to run the Docker container with TPU access
PROJECT_ID=\$(gcloud config get-value project)
sudo docker run --privileged --rm \\
  -e PJRT_DEVICE=TPU \\
  -e \$(grep -v \"^#\" \"\$HOME/tpu.env\" | xargs | sed \"s/ / -e /g\") \\
  -v /dev:/dev \\
  -v /lib/libtpu.so:/lib/libtpu.so \\
  -p 5000:5000 \\
  -p 6006:6006 \\
  gcr.io/\${PROJECT_ID}/tpu-hello-world:v1
EOF
chmod +x \"\$HOME/run_container.sh\""

log_success "Docker image setup completed."
log_success "TPU Setup Complete. TPU '$TPU_NAME' is ready." 