#!/bin/bash
# TPU VM Teardown Script - Deletes TPU VM resources
set -e

# ---- Script Constants and Imports ----
# Get the project directory (2 levels up from this script)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/../.." &> /dev/null && pwd )"
ENV_FILE="$PROJECT_DIR/config/.env"

# Import common utilities
source "$SCRIPT_DIR/../utils/common.sh"

# ---- Functions ----

# Validate environment variables and dependencies
function validate_environment() {
  log "Validating environment..."
  
  # Required environment variables
  check_env_vars "PROJECT_ID" "TPU_NAME" "TPU_ZONE" || exit 1
  
  # Display configuration
  display_config "PROJECT_ID" "TPU_NAME" "TPU_ZONE"
  
  # Set up authentication
  setup_auth
}

# Check if TPU exists and confirm deletion
function check_and_confirm() {
  # Check if TPU exists
  log "Checking if TPU '$TPU_NAME' exists..."
  if ! gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" &> /dev/null; then
    log_warning "TPU '$TPU_NAME' does not exist. Nothing to delete."
    exit 0
  fi
  
  # Confirm deletion
  if ! confirm_delete "TPU '$TPU_NAME'"; then
    log "Deletion cancelled."
    exit 0
  fi
}

# Delete the TPU VM
function delete_tpu() {
  log "Deleting TPU VM '$TPU_NAME'..."
  gcloud compute tpus tpu-vm delete "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --quiet
    
  log_success "TPU VM deleted successfully"
}

# Main function
function main() {
  # Initialize
  init_script 'TPU VM Teardown'
  
  # Load environment variables
  load_env_vars "$ENV_FILE"
  
  # Validate environment
  validate_environment
  
  # Check and confirm deletion
  check_and_confirm
  
  # Delete the TPU
  delete_tpu
  
  # Complete
  log_elapsed_time
}

# ---- Main Execution ----
main