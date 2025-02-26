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
  echo "Usage: $0 [--restart] [--watch]"
  echo ""
  echo "Sync all Python files from dev/src to the TPU VM and optionally restart the container."
  echo ""
  echo "Options:"
  echo "  --restart    Restart the Docker container after syncing"
  echo "  --watch      Watch for changes and sync automatically (requires fswatch)"
  echo "  -h, --help   Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0              # Sync all Python files once"
  echo "  $0 --restart    # Sync and restart container"
  echo "  $0 --watch      # Sync continuously when files change"
  echo ""
  echo "Note: This script can be run from any directory in the codebase"
  exit 1
}

sync_files() {
  log "Syncing files to TPU VM..."
  
  # Create the target directory
  gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
      --zone="$TPU_ZONE" \
      --project="$PROJECT_ID" \
      --worker=all \
      --command="mkdir -p /tmp/dev/src"
  
  # Copy all Python files
  for file in "$SRC_DIR"/*.py; do
    if [ -f "$file" ]; then
      base_file=$(basename "$file")
      log "- Syncing $base_file"
      gcloud compute tpus tpu-vm scp "$file" "$TPU_NAME":/tmp/dev/src/ \
          --zone="$TPU_ZONE" \
          --project="$PROJECT_ID" \
          --worker=all
    fi
  done
  
  log "Sync completed successfully"
}

restart_container() {
  log "Attempting to restart Docker container on TPU VM..."
  
  # Create a temporary script to run on the TPU VM
  TEMP_SCRIPT=$(mktemp)
  cat > "$TEMP_SCRIPT" << EOF
#!/bin/bash
echo "Looking for running Docker containers..."
CONTAINERS=\$(docker ps -q --filter ancestor=gcr.io/$PROJECT_ID/tpu-hello-world:v1 2>/dev/null)

if [ -z "\$CONTAINERS" ]; then
  echo "No running containers found to restart."
  echo "Starting a new container..."
  
  # Run a new container in the background with the mounted directory
  docker run -d --rm --privileged \\
    --device=/dev/accel0 \\
    -e PJRT_DEVICE=TPU \\
    -e XLA_USE_BF16=1 \\
    -e PYTHONUNBUFFERED=1 \\
    -v /tmp/dev/src:/app/dev/src \\
    -w /app \\
    gcr.io/$PROJECT_ID/tpu-hello-world:v1 \\
    /bin/bash -c "echo 'Container started, waiting for commands.' && sleep infinity"
    
  if [ \$? -ne 0 ]; then
    echo "Failed to start container with standard permissions, trying with sudo..."
    sudo docker run -d --rm --privileged \\
      --device=/dev/accel0 \\
      -e PJRT_DEVICE=TPU \\
      -e XLA_USE_BF16=1 \\
      -e PYTHONUNBUFFERED=1 \\
      -v /tmp/dev/src:/app/dev/src \\
      -w /app \\
      gcr.io/$PROJECT_ID/tpu-hello-world:v1 \\
      /bin/bash -c "echo 'Container started, waiting for commands.' && sleep infinity"
  fi
  
  echo "New background container started. Use run.sh to execute code."
else
  echo "Found running containers: \$CONTAINERS"
  echo "Restarting containers..."
  
  for container in \$CONTAINERS; do
    echo "Restarting container \$container..."
    if ! docker restart \$container; then
      echo "Failed with standard permissions, trying with sudo..."
      sudo docker restart \$container
    fi
  done
  
  echo "Container restart completed."
fi
EOF

  # Copy the script to the TPU VM
  gcloud compute tpus tpu-vm scp "$TEMP_SCRIPT" "$TPU_NAME":/tmp/restart_container.sh \
      --zone="$TPU_ZONE" \
      --project="$PROJECT_ID" \
      --worker=all
  
  # Make it executable and run it
  gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
      --zone="$TPU_ZONE" \
      --project="$PROJECT_ID" \
      --worker=all \
      --command="chmod +x /tmp/restart_container.sh && /tmp/restart_container.sh"
  
  # Clean up temporary file
  rm "$TEMP_SCRIPT"
  
  log "Container restart process completed"
}

# Set up error trapping
trap 'handle_error ${LINENO} $?' ERR

# --- MAIN SCRIPT ---
# Get the absolute path to the project root directory - works from any directory
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_DIR/dev/src"
RESTART_CONTAINER=false
WATCH_MODE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --restart)
      RESTART_CONTAINER=true
      shift
      ;;
    --watch)
      WATCH_MODE=true
      shift
      ;;
    -h|--help)
      show_usage
      ;;
    *)
      log "Unknown option: $1"
      show_usage
      ;;
  esac
done

log 'Starting TPU code synchronization process...'

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
log "- Restart container: $RESTART_CONTAINER"
log "- Watch mode: $WATCH_MODE"

# Set up authentication if provided
if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON" ]]; then
  log 'Setting up service account credentials...'
  export GOOGLE_APPLICATION_CREDENTIALS="$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON"
  gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
  log 'Service account authentication successful'
fi

# Check if the source directory exists
if [[ ! -d "$SRC_DIR" ]]; then
  log "ERROR: Source directory '$SRC_DIR' not found"
  exit 1
fi

# Check for Python files in the source directory
PYTHON_FILES=$(find "$SRC_DIR" -name "*.py" | wc -l)
if [[ $PYTHON_FILES -eq 0 ]]; then
  log "WARNING: No Python files found in $SRC_DIR"
  exit 0
fi

# If watch mode is enabled
if [[ "$WATCH_MODE" == "true" ]]; then
  # Check if fswatch is installed
  if ! command -v fswatch &> /dev/null; then
    log "ERROR: fswatch is not installed and is required for watch mode"
    log "Please install fswatch and try again"
    log "  - On macOS: brew install fswatch"
    log "  - On Ubuntu/Debian: sudo apt-get install fswatch"
    log "  - On Windows: Use Windows Subsystem for Linux (WSL) and install as per Ubuntu"
    exit 1
  fi
  
  # Initial sync
  log "Performing initial sync..."
  sync_files
  
  if [[ "$RESTART_CONTAINER" == "true" ]]; then
    restart_container
  fi
  
  log "Watching for changes in $SRC_DIR..."
  fswatch -o "$SRC_DIR" | while read -r line; do
    log "Change detected: $line"
    sync_files
    
    if [[ "$RESTART_CONTAINER" == "true" ]]; then
      restart_container
    fi
  done
else
  # One-time sync
  sync_files
  
  if [[ "$RESTART_CONTAINER" == "true" ]]; then
    restart_container
  fi
  
  log "Code synchronization completed successfully"
  log "To run synced files, use: ./dev/mgt/run.sh [filename.py]"
fi 