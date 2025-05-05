#!/bin/bash
# Common Utilities - Shared functions for infrastructure scripts
# These utilities provide standardized logging, error handling, and environment management

# ---- Constants and Variables ----
# Add colors to the output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script timing
SCRIPT_START_TIME=$(date +%s)

# ---- Logging Functions ----
# Standard log message
log() {
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo -e "[$timestamp] $1"
}

# Success log message (green)
log_success() {
  log "${GREEN}$1${NC}"
}

# Warning log message (yellow)
log_warning() {
  log "${YELLOW}$1${NC}"
}

# Error log message (red)
log_error() {
  log "${RED}$1${NC}"
}

# Section header (blue)
log_section() {
  echo -e "\n\033[1;34m=== $1 ===\033[0m"  # Bold blue section header
}

# Log elapsed time since script start
log_elapsed_time() {
  local end_time=$(date +%s)
  local elapsed=$((end_time - SCRIPT_START_TIME))
  local minutes=$((elapsed / 60))
  local seconds=$((elapsed % 60))
  log "Time elapsed: ${minutes}m ${seconds}s"
}

# ---- User Interaction Functions ----
# Ask for user confirmation with customizable prompt and default
confirm_action() {
  local prompt="$1"
  local default="$2"
  
  if [[ "$default" == "y" ]]; then
    prompt="$prompt [Y/n]: "
  else
    prompt="$prompt [y/N]: "
  fi
  
  read -p "$prompt" response
  response=${response,,} # Convert to lowercase
  
  if [[ "$default" == "y" ]]; then
    [[ -z "$response" || "$response" == "y" || "$response" == "yes" ]]
  else
    [[ "$response" == "y" || "$response" == "yes" ]]
  fi
}

# Specifically ask for deletion confirmation
confirm_delete() {
  local item_desc="${1:-these items}"
  confirm_action "Are you sure you want to delete $item_desc? This operation is irreversible" "n"
}

# ---- Error Handling ----
# Handle errors with line number and error code
handle_error() {
  local line_no=$1
  local error_code=$2
  log_error "Command failed at line $line_no with exit code $error_code"
  log_error "Check logs above for more details"
  log_elapsed_time
  exit $error_code
}

# Set up default error trapping - can be overridden in specific scripts
trap 'handle_error ${LINENO} $?' ERR

# ---- Script Initialization ----
# Initialize paths and environment for scripts
function init_script() {
  local script_name="${1:-Script}"
  
  # Set paths if not already defined by the calling script
  if [[ -z "$SCRIPT_DIR" || -z "$PROJECT_DIR" ]]; then
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[1]}" )" &> /dev/null && pwd )"
    PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
  fi
  
  # Ensure PROJECT_DIR is correctly set
  if [[ ! -d "$PROJECT_DIR/infrastructure/setup" || ! -d "$PROJECT_DIR/infrastructure/utils" ]]; then
    log_warning "Project directory structure doesn't look right: $PROJECT_DIR"
    log_warning "Attempting to find the correct project root..."
    
    # Try to find the project root by looking for setup and utils directories
    local current_dir=$(pwd)
    while [[ ! -d "$current_dir/infrastructure/setup" || ! -d "$current_dir/infrastructure/utils" ]] && [[ "$current_dir" != "/" ]]; do
      current_dir=$(dirname "$current_dir")
    done
    
    if [[ -d "$current_dir/infrastructure/setup" && -d "$current_dir/infrastructure/utils" ]]; then
      PROJECT_DIR="$current_dir"
      log_success "Found project root directory: $PROJECT_DIR"
    else
      log_error "Failed to find the project root directory containing required directories"
      exit 1
    fi
  fi
  
  log_section "$script_name"
  log "Starting process at $(date)"
  return 0
}

# ---- Environment Management ----
# Load environment variables from .env file
function load_env_vars() {
  local env_file="${1:-$PROJECT_DIR/config/.env}"
  
  log 'Loading environment variables...'
  if [[ -f "$env_file" ]]; then
    source "$env_file"
    log_success 'Environment variables loaded successfully'
    return 0
  else
    log_error "ERROR: .env file not found at $env_file"
    return 1
  fi
}

# Check if required environment variables are set
function check_env_vars() {
  local missing=false
  
  for var in "$@"; do
    if [ -z "${!var}" ]; then
      log_error "Required environment variable $var is not set."
      missing=true
    fi
  done
  
  if $missing; then
    log_error "Please set the required environment variables and try again."
    return 1
  fi
  
  return 0
}

# Configure TPU environment variables with sensible defaults
function configure_tpu_env() {
  # Set default TPU environment variables if not set
  export TPU_NAME=${TPU_NAME:-"local"}
  export TPU_LOAD_LIBRARY=${TPU_LOAD_LIBRARY:-"0"}
  export PJRT_DEVICE=${PJRT_DEVICE:-"TPU"}
  export XLA_USE_BF16=${XLA_USE_BF16:-"1"}
  export NEXT_PLUGGABLE_DEVICE_USE_C_API=${NEXT_PLUGGABLE_DEVICE_USE_C_API:-"true"}
  export TF_PLUGGABLE_DEVICE_LIBRARY_PATH=${TF_PLUGGABLE_DEVICE_LIBRARY_PATH:-"/lib/libtpu.so"}
  
  log "TPU environment variables configured with defaults where needed"
}

# Display script configuration based on specified variables
function display_config() {
  log "Configuration:"
  for var in "$@"; do
    if [[ -n "${!var}" ]]; then
      log "- $var: ${!var}"
    else
      log "- $var: [not set]"
    fi
  done
}

# Setup authentication for Google Cloud
function setup_auth() {
  if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$PROJECT_DIR/config/$SERVICE_ACCOUNT_JSON" ]]; then
    log "Setting up service account authentication..."
    export GOOGLE_APPLICATION_CREDENTIALS="$PROJECT_DIR/config/$SERVICE_ACCOUNT_JSON"
    gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
    log_success "Service account authentication successful"
    return 0
  else
    # Check if already authenticated
    if gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "@"; then
      log "Using existing GCP authentication"
      return 0
    else
      log_warning "No service account credentials found or file doesn't exist."
      log_warning "Authentication will use default credentials."
      return 1
    fi
  fi
}

# Ensure a directory exists
function ensure_directory() {
  local dir=$1
  if [[ ! -d "$dir" ]]; then
    log "Creating directory: $dir"
    mkdir -p "$dir"
  fi
}

# ---- SSH and Docker Functions ----
# Execute SSH command on TPU VM
function vmssh() {
  local cmd="$1"
  local worker="${2:-all}"  # Default to all workers if not specified
  
  log "Executing SSH command on TPU VM (worker: $worker)"
  
  # Execute the command on the TPU VM
  gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker="$worker" \
    --force-key-file-overwrite \
    --command="$cmd"
  
  local exit_code=$?
  
  if [ $exit_code -ne 0 ]; then
    log_error "Command failed at line $BASH_LINENO with exit code $exit_code"
    log_error "Check logs above for more details"
  fi
  
  return $exit_code
}

# Execute SSH command and capture output to file
function vmssh_out() {
  local cmd="$1"
  local output_dir="$2"
  local worker="${3:-0}"  # Default to worker 0
  
  log "Executing SSH command with output capture to directory"
  
  # Execute command with output captured to directory
  gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID" \
    --worker="$worker" \
    --force-key-file-overwrite \
    --command="$cmd" \
    --output-directory="$output_dir" \
  
  local exit_code=$?
  
  if [ $exit_code -ne 0 ] && [ $exit_code -ne 127 ]; then
    log_error "Command failed with exit code $exit_code"
  fi
}

# Copy files to TPU VM via SCP
function vmscp() {
  local src="$1"
  local dest="$2"
  local worker="${3:-0}"  # Default to worker 0 if not specified
  
  log "Copying files to TPU VM (worker: $worker)"
  
  # Execute the SCP command with proper parameters
  gcloud compute tpus tpu-vm scp \
    "$src" \
    "${TPU_NAME}:$dest" \
    --project="${PROJECT_ID}" \
    --zone="${TPU_ZONE}" \
    --worker="$worker" \
    --force-key-file-overwrite
  
  local exit_code=$?
  
  if [ $exit_code -ne 0 ]; then
    log_error "SCP transfer failed with exit code $exit_code"
    return $exit_code
  else
    log_success "Files transferred successfully"
    return 0
  fi
}

# Generate Docker command with TPU access
function generate_docker_cmd() {
  local IMAGE_NAME="$1"
  local TPU_LIB_PATH="$2"
  local COMMAND="$3"
  local EXTRA_ARGS="${4:-""}"
  local EXTRA_MOUNTS="${5:-""}"
  
  echo "docker run --rm --privileged \\
    --device=/dev/accel0 \\
    -e PJRT_DEVICE=TPU \\
    -e PYTHONUNBUFFERED=1 \\
    $EXTRA_ARGS \\
    -v ~/mount:/app/mount \\
    -v /usr/share/tpu/:/usr/share/tpu/ \\
    -v $TPU_LIB_PATH:$TPU_LIB_PATH \\
    $EXTRA_MOUNTS \\
    $IMAGE_NAME \\
    $COMMAND"
} 