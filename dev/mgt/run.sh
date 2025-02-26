#!/bin/bash

# --- HELPER FUNCTIONS ---
log() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] $1"
}

handle_error() {
  local line_no=$1
  local error_code=$2
  log "ERROR: Command failed at line $line_no with exit code $error_code"
  exit $error_code
}

show_usage() {
  echo "Usage: $0 [filename1.py filename2.py ...] [args...]"
  echo ""
  echo "Execute one or more Python files from the mounted development directory on the TPU VM."
  echo ""
  echo "Arguments:"
  echo "  filename1.py, filename2.py   Python files to execute (must be in dev/src and previously mounted)"
  echo "  args...                      Optional arguments to pass to the Python scripts"
  echo ""
  echo "Examples:"
  echo "  $0 example.py                # Run example.py"
  echo "  $0 preprocess.py train.py    # Run multiple files sequentially"
  echo "  $0 model.py --epochs 10      # Run with arguments"
  echo ""
  echo "Notes:"
  echo "  - This script can be run from any directory in the codebase"
  echo "  - Files must be mounted first using 'mount.sh' (or will be auto-mounted)"
  echo "  - When passing arguments, they apply to the last Python file only"
  exit 1
}

# Set up error trapping
trap 'handle_error ${LINENO} $?' ERR

# --- MAIN SCRIPT ---
# Get the absolute path to the project root directory - works from any directory
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_DIR/dev/src"

# Parse command line arguments
if [ $# -eq 0 ]; then
  show_usage
fi

# Collect all Python files to run
FILES_TO_RUN=()
SCRIPT_ARGS=()
COLLECTING_FILES=true

for arg in "$@"; do
  # If we're collecting files and this looks like a Python file, add it to FILES_TO_RUN
  if [[ "$COLLECTING_FILES" == "true" && "$arg" == *.py ]]; then
    FILES_TO_RUN+=("$arg")
  else
    # Once we encounter a non-Python file, we're collecting arguments
    COLLECTING_FILES=false
    SCRIPT_ARGS+=("$arg")
  fi
done

# Ensure we have at least one file to run
if [ ${#FILES_TO_RUN[@]} -eq 0 ]; then
  log "ERROR: No Python files specified"
  show_usage
fi

log 'Loading environment variables...'
source "$PROJECT_DIR/source/.env"
log 'Environment variables loaded successfully'

# Validate required environment variables
if [[ -z "$PROJECT_ID" || -z "$TPU_ZONE" || -z "$TPU_NAME" ]]; then
  log "ERROR: Required environment variables are missing"
  log "Ensure PROJECT_ID, TPU_ZONE, and TPU_NAME are set in .env"
  exit 1
fi

log "Configuration:"
log "- Project ID: $PROJECT_ID"
log "- TPU Zone: $TPU_ZONE"
log "- TPU Name: $TPU_NAME"
log "- Scripts to run: ${FILES_TO_RUN[*]}"
if [ ${#SCRIPT_ARGS[@]} -gt 0 ]; then
  log "- Script arguments: ${SCRIPT_ARGS[*]}"
fi

# Set up authentication if provided
if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON" ]]; then
  log 'Setting up service account credentials...'
  export GOOGLE_APPLICATION_CREDENTIALS="$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON"
  gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
  log 'Service account authentication successful'
fi

# Check each file exists locally and is mounted on the TPU VM
for FILE_TO_RUN in "${FILES_TO_RUN[@]}"; do
  # Check if the file exists locally
  if [[ ! -f "$SRC_DIR/$FILE_TO_RUN" ]]; then
    log "ERROR: File '$FILE_TO_RUN' not found in $SRC_DIR"
    exit 1
  fi
  
  # Check if the file is mounted on the TPU VM
  log "Verifying that '$FILE_TO_RUN' is mounted on TPU VM..."
  FILE_MOUNTED=$(gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
      --zone="$TPU_ZONE" \
      --project="$PROJECT_ID" \
      --worker=all \
      --command="[ -f /tmp/dev/src/$FILE_TO_RUN ] && echo 'YES' || echo 'NO'")

  if [[ "$FILE_MOUNTED" != "YES" ]]; then
    log "File '$FILE_TO_RUN' not found on TPU VM - auto-mounting..."
    
    # Create directory if it doesn't exist
    gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
        --zone="$TPU_ZONE" \
        --project="$PROJECT_ID" \
        --worker=all \
        --command="mkdir -p /tmp/dev/src"
        
    # Mount the file
    gcloud compute tpus tpu-vm scp "$SRC_DIR/$FILE_TO_RUN" "$TPU_NAME":/tmp/dev/src/ \
        --zone="$TPU_ZONE" \
        --project="$PROJECT_ID" \
        --worker=all
        
    # Check again
    FILE_MOUNTED=$(gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
        --zone="$TPU_ZONE" \
        --project="$PROJECT_ID" \
        --worker=all \
        --command="[ -f /tmp/dev/src/$FILE_TO_RUN ] && echo 'YES' || echo 'NO'")
        
    if [[ "$FILE_MOUNTED" != "YES" ]]; then
      log "ERROR: Failed to mount file '$FILE_TO_RUN' to TPU VM"
      exit 1
    fi
    
    log "File '$FILE_TO_RUN' successfully mounted"
  fi
done

# Create a temporary script to run on the TPU VM
TEMP_SCRIPT=$(mktemp)
cat > "$TEMP_SCRIPT" << EOF
#!/bin/bash
# Set debug options
if [[ "$TPU_DEBUG" == "true" ]]; then
  echo "Debug mode enabled - verbose logging"
  DEBUG_OPTS="-e TF_CPP_MIN_LOG_LEVEL=0 -e XLA_FLAGS=--xla_dump_to=/tmp/xla_dump"
else
  DEBUG_OPTS="-e TF_CPP_MIN_LOG_LEVEL=3"
fi

# Check TPU health
echo "Checking TPU health..."
if ! ls -la /dev/accel* &>/dev/null; then
  echo "ERROR: No TPU devices found at /dev/accel*"
  echo "Please check if TPU is properly initialized"
  exit 1
fi

# Base Docker command
DOCKER_CMD="docker run --rm --privileged \\
  --device=/dev/accel0 \\
  -e PJRT_DEVICE=TPU \\
  -e XLA_USE_BF16=1 \\
  -e PYTHONUNBUFFERED=1 \\
  \$DEBUG_OPTS \\
  -v /tmp/dev/src:/app/dev/src \\
  -w /app \\
  gcr.io/$PROJECT_ID/tpu-hello-world:v1"

# Sudo Docker command (fallback)
SUDO_DOCKER_CMD="sudo \$DOCKER_CMD"

EOF

# Add loop through files to the script
cat >> "$TEMP_SCRIPT" << EOF
# Run each file sequentially
FILES_TO_RUN=(${FILES_TO_RUN[@]})
SCRIPT_ARGS="${SCRIPT_ARGS[@]}"

for ((i=0; i<\${#FILES_TO_RUN[@]}; i++)); do
  FILE="\${FILES_TO_RUN[i]}"
  echo ""
  echo "======================="
  echo "Running file \$((i+1))/\${#FILES_TO_RUN[@]}: \$FILE"
  echo "======================="
  
  # Only pass arguments to the last file
  if [ \$i -eq \$((${#FILES_TO_RUN[@]}-1)) ] && [ -n "$SCRIPT_ARGS" ]; then
    ARGS="\$SCRIPT_ARGS"
  else
    ARGS=""
  fi
  
  # Try normal docker run first
  echo "Running with standard Docker..."
  if eval "\$DOCKER_CMD python dev/src/\$FILE \$ARGS"; then
    echo "Execution of '\$FILE' completed successfully"
  else
    echo "Standard Docker failed, trying with sudo..."
    if eval "\$SUDO_DOCKER_CMD python dev/src/\$FILE \$ARGS"; then
      echo "Execution of '\$FILE' completed successfully with sudo"
    else
      echo "ERROR: Failed to run '\$FILE' even with sudo"
      exit 1
    fi
  fi
done

echo "All files executed successfully"
EOF

# Copy the script to the TPU VM
log "Copying runner script to TPU VM..."
gcloud compute tpus tpu-vm scp "$TEMP_SCRIPT" "$TPU_NAME":/tmp/run_dev_script.sh \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all

# Make it executable and run it
log "Running script(s) inside Docker container on TPU VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all \
    --command="chmod +x /tmp/run_dev_script.sh && PROJECT_ID=$PROJECT_ID TPU_DEBUG=${TPU_DEBUG:-false} /tmp/run_dev_script.sh"

# Clean up temporary file
rm "$TEMP_SCRIPT"

log "Script execution complete." 