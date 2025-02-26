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
  echo "Remove specified mounted files from the TPU VM."
  echo ""
  echo "Options:"
  echo "  -a, --all    Remove all files from the mounted directory"
  echo "  -h, --help   Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 example.py               # Remove only example.py"
  echo "  $0 model.py data_utils.py   # Remove multiple specific files"
  echo "  $0 --all                    # Remove all mounted files"
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
REMOVE_ALL=false
FILES_TO_REMOVE=()

# Parse command line arguments
if [ $# -eq 0 ]; then
  show_usage
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    -a|--all)
      REMOVE_ALL=true
      shift # shift past the argument
      ;;
    -h|--help)
      show_usage
      ;;
    *)
      # Assume this is a file to remove
      FILES_TO_REMOVE+=("$1")
      shift # shift past the argument
      ;;
  esac
done

log 'Starting TPU development environment cleanup process...'

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

# Get current list of files in the mounted directory
log "Checking current mounted files..."
TEMP_FILE=$(mktemp)
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all \
    --command="ls -1 /tmp/dev/src/ 2>/dev/null || echo 'EMPTY'" > "$TEMP_FILE"

# Check if the directory exists or is empty
if grep -q "EMPTY" "$TEMP_FILE"; then
  log "No mounted files found or directory doesn't exist"
  rm "$TEMP_FILE"
  exit 0
fi

# Process the file list
CURRENT_FILES=()
while IFS= read -r line; do
  if [[ -n "$line" && "$line" != "EMPTY" ]]; then
    CURRENT_FILES+=("$line")
  fi
done < "$TEMP_FILE"
rm "$TEMP_FILE"

if [[ ${#CURRENT_FILES[@]} -eq 0 ]]; then
  log "No mounted files found"
  exit 0
fi

log "Current mounted files: ${CURRENT_FILES[*]}"

# Determine which files to remove
if [[ "$REMOVE_ALL" == "true" ]]; then
  log "Preparing to remove all mounted files"
  FILES_TO_REMOVE=("${CURRENT_FILES[@]}")
else
  log "Preparing to remove specified files: ${FILES_TO_REMOVE[*]}"
  # Validate that the specified files exist in the mounted directory
  for file in "${FILES_TO_REMOVE[@]}"; do
    if ! echo "${CURRENT_FILES[@]}" | grep -q "$file"; then
      log "WARNING: File '$file' not found in mounted directory"
    fi
  done
fi

if [[ ${#FILES_TO_REMOVE[@]} -eq 0 ]]; then
  log "No files to remove"
  exit 0
fi

# Remove each file from the TPU VM
log "Removing files from TPU VM..."
for file in "${FILES_TO_REMOVE[@]}"; do
  log "- Removing $file"
  gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
      --zone="$TPU_ZONE" \
      --project="$PROJECT_ID" \
      --worker=all \
      --command="rm -f /tmp/dev/src/$file"
done

# Verify files were removed successfully
log "Verifying files were removed from TPU VM..."
TEMP_FILE=$(mktemp)
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker=all \
    --command="ls -1 /tmp/dev/src/ 2>/dev/null || echo 'EMPTY'" > "$TEMP_FILE"

REMAINING_FILES=()
if ! grep -q "EMPTY" "$TEMP_FILE"; then
  while IFS= read -r line; do
    if [[ -n "$line" && "$line" != "EMPTY" ]]; then
      REMAINING_FILES+=("$line")
    fi
  done < "$TEMP_FILE"
fi
rm "$TEMP_FILE"

# Check if any of the files that should have been removed are still present
FAILED_REMOVALS=()
for file in "${FILES_TO_REMOVE[@]}"; do
  if echo "${REMAINING_FILES[@]}" | grep -q "$file"; then
    FAILED_REMOVALS+=("$file")
  fi
done

if [[ ${#FAILED_REMOVALS[@]} -gt 0 ]]; then
  log "WARNING: Failed to remove the following files: ${FAILED_REMOVALS[*]}"
else
  log "All specified files successfully removed"
fi

if [[ ${#REMAINING_FILES[@]} -gt 0 ]]; then
  log "Remaining mounted files: ${REMAINING_FILES[*]}"
else
  log "No files remain in the mounted directory"
  # If all files were removed and the directory is empty, optionally remove the directory
  if [[ "$REMOVE_ALL" == "true" ]]; then
    log "Removing empty mounted directory..."
    gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
        --zone="$TPU_ZONE" \
        --project="$PROJECT_ID" \
        --worker=all \
        --command="rm -rf /tmp/dev/src"
    log "Mounted directory removed"
  fi
fi

log "Cleanup process completed." 