#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common.sh"

# --- MAIN SCRIPT ---
init_script "TPU zone availability check"
ENV_FILE="$PROJECT_DIR/source/.env"
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" "TPU_REGION" "TPU_TYPE" || exit 1

# Display configuration
display_config "PROJECT_ID" "TPU_REGION" "TPU_TYPE"

# Set up authentication
setup_auth

# Get all zones in the region - a simpler approach for Windows compatibility
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

# Check zones for TPU availability
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

# Update .env file with the found zone
if [[ -n "$FOUND_ZONE" ]]; then
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
else
    log_error "TPU type '$TPU_TYPE' not found in any zone in region '$TPU_REGION'"
    log_error "Please check if the TPU type is correct and available in the region."
    exit 1
fi

log_success "Zone availability check completed successfully"