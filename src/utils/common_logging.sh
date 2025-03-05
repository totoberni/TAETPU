#!/bin/bash

# --- COMMON LOGGING FUNCTIONS ---
log() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] $1"
}

log_success() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "[$timestamp] \033[0;32m$1\033[0m"  # Green
}

log_warning() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "[$timestamp] \033[0;33m$1\033[0m"  # Yellow
}

log_error() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "[$timestamp] \033[0;31m$1\033[0m"  # Red
}

log_section() {
  echo -e "\n\033[1;34m=== $1 ===\033[0m"  # Bold blue section header
}

# --- SCRIPT STATUS TRACKING ---
SCRIPT_START_TIME=$(date +%s)

log_elapsed_time() {
  local end_time=$(date +%s)
  local elapsed=$((end_time - SCRIPT_START_TIME))
  local minutes=$((elapsed / 60))
  local seconds=$((elapsed % 60))
  log "Time elapsed: ${minutes}m ${seconds}s"
}

# --- ERROR HANDLING ---
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

# --- SCRIPT INITIALIZATION ---
# Initialize paths and environment for setup scripts
function init_script() {
  local script_name="${1:-Script}"
  
  # Set paths if not already defined by the calling script
  if [[ -z "$SCRIPT_DIR" || -z "$PROJECT_DIR" ]]; then
    SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[1]}" )" &> /dev/null && pwd )"
    PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
  fi
  
  # Ensure PROJECT_DIR is correctly set
  if [[ ! -d "$PROJECT_DIR/src" ]]; then
    log_warning "Project directory structure doesn't look right: $PROJECT_DIR"
    log_warning "Attempting to find the correct project root..."
    
    # Try to find the project root by looking for the src directory
    local current_dir=$(pwd)
    while [[ ! -d "$current_dir/src" && "$current_dir" != "/" ]]; do
      current_dir=$(dirname "$current_dir")
    done
    
    if [[ -d "$current_dir/src" ]]; then
      PROJECT_DIR="$current_dir"
      log_success "Found project root directory: $PROJECT_DIR"
    else
      log_error "Failed to find the project root directory containing 'src'"
      exit 1
    fi
  fi
  
  log_section "$script_name"
  log "Starting process at $(date)"
  return 0
}

# --- ENVIRONMENT MANAGEMENT ---
# Load environment variables from .env file
function load_env_vars() {
  local env_file="${1:-$PROJECT_DIR/source/.env}"
  
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

# --- UTILITIES ---
function check_env_vars() {
  local missing=0
  local missing_vars=()
  
  for var in "$@"; do
    if [[ -z "${!var}" ]]; then
      missing_vars+=("$var")
      missing=1
    fi
  done
  
  if [[ $missing -eq 1 ]]; then
    log_error "Required environment variable(s) not set: ${missing_vars[*]}"
    log_error "Please make sure these are defined in your .env file"
  fi
  
  return $missing
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

function setup_auth() {
  if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON" ]]; then
    log "Setting up service account authentication..."
    export GOOGLE_APPLICATION_CREDENTIALS="$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON"
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

function ensure_directory() {
  local dir=$1
  if [[ ! -d "$dir" ]]; then
    log "Creating directory: $dir"
    mkdir -p "$dir"
  fi
}

# --- SSH HELPERS ---
# Execute SSH command with timeout
ssh_with_timeout() {
  local cmd="$1"
  local timeout_seconds="${2:-30}"
  local ssh_result=0
  
  log "Executing SSH command (timeout: ${timeout_seconds}s)"
  timeout "$timeout_seconds" gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" --project="$PROJECT_ID" \
    --command="$cmd" || ssh_result=$?
  
  if [ $ssh_result -eq 124 ]; then
    log_warning "SSH command timed out after $timeout_seconds seconds"
    return 124
  elif [ $ssh_result -ne 0 ]; then
    log_error "SSH command failed with code $ssh_result"
    return $ssh_result
  fi
  
  return 0
}

# Execute SSH command on all TPU workers with timeout
ssh_all_with_timeout() {
  local cmd="$1"
  local timeout_seconds="${2:-30}"
  local ssh_result=0
  
  log "Executing SSH command on all workers (timeout: ${timeout_seconds}s)"
  timeout "$timeout_seconds" gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" --project="$PROJECT_ID" \
    --worker=all --command="$cmd" || ssh_result=$?
  
  if [ $ssh_result -eq 124 ]; then
    log_warning "SSH all-workers command timed out after $timeout_seconds seconds"
    return 124
  elif [ $ssh_result -ne 0 ]; then
    log_error "SSH all-workers command failed with code $ssh_result"
    return $ssh_result
  fi
  
  return 0
}

# --- DOCKER HELPERS ---
Generate Docker command with TPU access
function generate_docker_cmd() {
  local IMAGE_NAME="$1"
  local TPU_LIB_PATH="$2"
  local COMMAND="$3"
  local EXTRA_ARGS="${4:-""}"
  local EXTRA_MOUNTS="${5:-""}"
  
  echo "docker run --rm --privileged \\
    --device=/dev/accel0 \\
    -e PJRT_DEVICE=TPU \\
    -e XLA_USE_BF16=1 \\
    -e PYTHONUNBUFFERED=1 \\
    -e TPU_NAME=local \\
    -e TPU_LOAD_LIBRARY=0 \\
    -e TF_PLUGGABLE_DEVICE_LIBRARY_PATH=$TPU_LIB_PATH \\
    -e NEXT_PLUGGABLE_DEVICE_USE_C_API=true \\
    $EXTRA_ARGS \\
    -v /tmp/dev/src:/app/dev/src \\
    -v $TPU_LIB_PATH:$TPU_LIB_PATH \\
    $EXTRA_MOUNTS \\
    $IMAGE_NAME \\
    $COMMAND"
} 