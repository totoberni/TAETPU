#!/bin/bash
# TPU Zone Availability Check - Finds available zones for specified TPU type
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
  check_env_vars "PROJECT_ID" "TPU_REGION" "TPU_TYPE" || exit 1
  load_env_vars "$ENV_FILE"
  # Display configuration
  display_config "PROJECT_ID" "TPU_REGION" "TPU_TYPE"
  
  # Set up authentication
  setup_auth
}

# Get all available zones in the specified region
function get_available_zones() {
  log "Fetching available TPU zones in region '$TPU_REGION'..."
  ZONES_RAW=$(gcloud compute zones list --filter="name ~ ^$TPU_REGION" --format="value(name)")
  
  # Create a properly formatted array with clean zone names
  ZONES=()
  while read -r zone; do
    # Trim any whitespace or special characters
    zone=$(echo "$zone" | tr -d '\r\n')
    if [[ -n "$zone" ]]; then
      ZONES+=("$zone")
    fi
  done <<< "$ZONES_RAW"
  
  if [[ ${#ZONES[@]} -eq 0 ]]; then
    log_error "No zones found in region '$TPU_REGION'"
    exit 1
  fi
  
  log "Found ${#ZONES[@]} zones in region '$TPU_REGION'"
  for zone in "${ZONES[@]}"; do
    log "- $zone"
  done
  
  return 0
}

# Check zones for TPU availability
function find_tpu_zone() {
  FOUND_ZONE=""
  
  for zone in "${ZONES[@]}"; do
    log "Checking zone '$zone' for TPU type '$TPU_TYPE'..."
    
    # Save the output to a file to avoid line ending issues
    TPU_OUTPUT_FILE=$(mktemp)
    gcloud compute tpus tpu-vm accelerator-types list --zone="$zone" --project="$PROJECT_ID" > "$TPU_OUTPUT_FILE" 2>/dev/null
    
    # Check if our TPU type is in the output file
    if grep -q "ACCELERATOR_TYPE:.*$TPU_TYPE" "$TPU_OUTPUT_FILE"; then
      log_success "✓ TPU type '$TPU_TYPE' found in zone '$zone'!"
      FOUND_ZONE="$zone"
      rm "$TPU_OUTPUT_FILE"
      break
    else
      log "× TPU type '$TPU_TYPE' not found in zone '$zone'"
    fi
    
    # Clean up
    rm "$TPU_OUTPUT_FILE"
  done
  
  if [[ -z "$FOUND_ZONE" ]]; then
    log_error "TPU type '$TPU_TYPE' not found in any zone in region '$TPU_REGION'"
    log_error "Please check if the TPU type is correct and available in the region."
    exit 1
  fi
  
  return 0
}

# Update .env file with the found zone
function update_env_file() {
  log_success "Successfully found matching zone: $FOUND_ZONE"
  
  # Check if .env file is writable
  if [[ ! -w "$ENV_FILE" ]]; then
    log_error "Cannot write to .env file. Please check permissions."
    exit 1
  fi
  
  # Use appropriate sed command based on OS
  if [[ "$(uname)" == "Darwin" ]]; then
    # macOS
    sed -i '' "s/^TPU_ZONE=.*$/TPU_ZONE=$FOUND_ZONE/" "$ENV_FILE"
  else
    # Linux/Windows
    sed -i "s/^TPU_ZONE=.*$/TPU_ZONE=$FOUND_ZONE/" "$ENV_FILE"
  fi
  
  # Verify update
  if grep -q "^TPU_ZONE=$FOUND_ZONE" "$ENV_FILE"; then
    log_success "Updated .env file with TPU_ZONE=$FOUND_ZONE"
  else
    log_warning "Failed to update TPU_ZONE in .env file. Please manually set TPU_ZONE=$FOUND_ZONE"
  fi
}

# Main function
function main() {
  # Initialize
  init_script "TPU zone availability check"
  
  # Load environment variables
  load_env_vars "$ENV_FILE"
  
  # Validate environment
  validate_environment
  
  # Get available zones
  get_available_zones
  
  # Find zone with the requested TPU type
  find_tpu_zone
  
  # Update .env file with the found zone
  update_env_file
  
  # Completed
  log_success "Zone availability check completed successfully"
}

# ---- Main Execution ----
main