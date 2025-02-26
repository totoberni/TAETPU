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
  echo "Usage: $0 [-a|--all] [file1.py file2.py ...]"
  echo ""
  echo "Mount specified files from dev/src to the TPU VM container."
  echo ""
  echo "Options:"
  echo "  -a, --all    Mount all files from dev/src directory"
  echo "  -h, --help   Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 example.py               # Mount only example.py"
  echo "  $0 model.py data_utils.py   # Mount multiple specific files"
  echo "  $0 --all                    # Mount all files in dev/src"
  echo ""
  echo "Note: This script can be run from any directory in the codebase"
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
MOUNT_ALL=false
FILES_TO_MOUNT=()

# Parse command line arguments
if [ $# -eq 0 ]; then
  show_usage
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    -a|--all)
      MOUNT_ALL=true
      shift # shift past the argument
      ;;
    -h|--help)
      show_usage
      ;;
    *)
      # Assume this is a file to mount
      FILES_TO_MOUNT+=("$1")
      shift # shift past the argument
      ;;
  esac
done

log 'Starting TPU development environment mount process...'

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

# Set up authentication if provided
if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON" ]]; then
  log 'Setting up service account credentials...'
  export GOOGLE_APPLICATION_CREDENTIALS="$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON"
  gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
  log 'Service account authentication successful'
fi

# Determine which files to mount
if [[ "$MOUNT_ALL" == "true" ]]; then
  log "Preparing to mount all files from dev/src directory"
  # Get all Python files in the src directory
  FILES_TO_MOUNT=()
  while IFS= read -r -d '' file; do
    FILES_TO_MOUNT+=("$(basename "$file")")
  done < <(find "$SRC_DIR" -type f -name "*.py" -print0)
  
  if [[ ${#FILES_TO_MOUNT[@]} -eq 0 ]]; then
    log "WARNING: No Python files found in $SRC_DIR"
    exit 0
  fi
else
  log "Preparing to mount specified files: ${FILES_TO_MOUNT[*]}"
  # Validate that the specified files exist
  for file in "${FILES_TO_MOUNT[@]}"; do
    if [[ ! -f "$SRC_DIR/$file" ]]; then
      log "ERROR: File '$file' not found in $SRC_DIR"
      exit 1
    fi
  done
fi

# Create directory on TPU VM for mounting
log "Setting up TPU VM for file mounting..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all \
    --command="mkdir -p /tmp/dev/src"

# Copy each file to the TPU VM
log "Copying files to TPU VM..."
for file in "${FILES_TO_MOUNT[@]}"; do
  log "- Mounting $file"
  gcloud compute tpus tpu-vm scp "$SRC_DIR/$file" "$TPU_NAME":/tmp/dev/src/ \
      --zone="$TPU_ZONE" \
      --project="$PROJECT_ID" \
      --worker=all
done

# List mounted files for verification
log "Verifying mounted files on TPU VM..."
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all \
    --command="ls -la /tmp/dev/src/"

log "Mount process completed successfully."
log "Files are available in the Docker container when mounted at /app/dev/src"
log "To run these files, use: ./dev/mgt/run.sh [filename.py]" 