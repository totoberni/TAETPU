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

# --- ERROR HANDLING ---
handle_error() {
  local line_no=$1
  local error_code=$2
  log_error "Command failed at line $line_no with exit code $error_code"
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
  
  log "Starting $script_name process..."
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
  local required_vars=("$@")
  local missing_vars=()
  
  for var in "${required_vars[@]}"; do
    if [[ -z "${!var}" ]]; then
      missing_vars+=("$var")
    fi
  done
  
  if [[ ${#missing_vars[@]} -gt 0 ]]; then
    log_error "Required environment variable(s) not set: ${missing_vars[*]}"
    log_error "Please make sure these are defined in your .env file"
    return 1
  fi
  
  return 0
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
    log_warning "No service account credentials found or file doesn't exist."
    log_warning "Authentication will use default credentials."
    return 1
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
  local timeout_seconds="${2:-10}"
  local ssh_result=0
  
  timeout "$timeout_seconds" gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" --project="$PROJECT_ID" \
    --command="$cmd" || ssh_result=$?
  
  if [ $ssh_result -eq 124 ]; then
    log_warning "SSH command timed out after $timeout_seconds seconds: $cmd"
    return 124
  elif [ $ssh_result -ne 0 ]; then
    log_error "SSH command failed with code $ssh_result: $cmd"
    return $ssh_result
  fi
  
  return 0
}

# Execute SSH command on all TPU workers with timeout
ssh_all_with_timeout() {
  local cmd="$1"
  local timeout_seconds="${2:-10}"
  local ssh_result=0
  
  timeout "$timeout_seconds" gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" --project="$PROJECT_ID" \
    --worker=all --command="$cmd" || ssh_result=$?
  
  if [ $ssh_result -eq 124 ]; then
    log_warning "SSH all-workers command timed out after $timeout_seconds seconds: $cmd"
    return 124
  elif [ $ssh_result -ne 0 ]; then
    log_error "SSH all-workers command failed with code $ssh_result: $cmd"
    return $ssh_result
  fi
  
  return 0
} 