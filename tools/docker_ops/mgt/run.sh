#!/bin/bash

# --- Basic setup ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/infrastructure/utils/common.sh"

# --- Parse arguments ---
if [ $# -eq 0 ] || [[ "$1" != *.py ]]; then
  echo "Usage: $0 [filename.py] [script_args...]"
  echo "Run Python file on TPU VM."
  exit 1
fi

PYTHON_FILE=$(basename "$1")
PYTHON_DIR=$(dirname "$1")
if [ "$PYTHON_DIR" = "." ]; then
  PYTHON_PATH="$PYTHON_FILE"
else
  PYTHON_PATH="$PYTHON_DIR/$PYTHON_FILE"
fi
shift
SCRIPT_ARGS=("$@")

# --- Load environment variables ---
source "$PROJECT_DIR/config/.env"
check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_NAME" || exit 1

# --- Define Docker image path ---
DOCKER_IMAGE="eu.gcr.io/${PROJECT_ID}/tae-tpu:v1"

# --- Verify file exists ---
log_section "File Verification"
log "Verifying $PYTHON_PATH exists on TPU VM"

# Direct verification using exit code rather than output capture
vmssh "test -f /app/mount/src/$PYTHON_PATH"

if [ $? -ne 0 ]; then
  log_error "File $PYTHON_PATH not found on TPU VM. Please mount it first."
  exit 1
fi

log_success "File verified successfully"

# --- Run the container ---
log_section "Running Script"
log "Running $PYTHON_PATH on TPU VM"

# Note: We use the environment variables already defined in the container
DOCKER_CMD="docker run --rm --privileged \
  --device=/dev/accel0 \
  -v /app/mount/src:/app/mount/src \
  -v /lib/libtpu.so:/lib/libtpu.so \
  -w /app \
  $DOCKER_IMAGE \
  python /app/mount/src/$PYTHON_PATH"

# Add script arguments
for arg in "${SCRIPT_ARGS[@]}"; do
  DOCKER_CMD+=" \"$arg\""
done

# Execute with or without sudo
vmssh "sudo $DOCKER_CMD" || vmssh "$DOCKER_CMD"

log_success "Execution complete"
exit 0