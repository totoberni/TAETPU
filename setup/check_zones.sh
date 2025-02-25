#!/bin/bash

# Helper function for logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Error handling function
handle_error() {
    local line_no=$1
    local error_code=$2
    log "ERROR: Command failed at line $line_no with exit code $error_code"
    exit $error_code
}

# Set up error trapping
trap 'handle_error ${LINENO} $?' ERR

# Load environment variables
log "Loading environment variables..."
# Fix the path to .env - use script directory as reference
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "$SCRIPT_DIR/../source/.env"

# Validate required environment variables
if [[ -z "$PROJECT_ID" || -z "$TPU_REGION" || -z "$TPU_TYPE" ]]; then
    log "ERROR: Required environment variables are missing."
    log "Ensure PROJECT_ID, TPU_REGION, and TPU_TYPE are set in .env file."
    exit 1
fi

log "Configuration:"
log "- Project ID: $PROJECT_ID"
log "- TPU Region: $TPU_REGION"
log "- TPU Type: $TPU_TYPE"

# Set up authentication if provided
if [[ -n "$SERVICE_ACCOUNT_JSON" && -f "$SCRIPT_DIR/../source/$SERVICE_ACCOUNT_JSON" ]]; then
    log "Authenticating with service account..."
    export GOOGLE_APPLICATION_CREDENTIALS="$SCRIPT_DIR/../source/$SERVICE_ACCOUNT_JSON"
    gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"
    log "Service account authentication successful"
fi

# Get all zones in the region (with proper trimming)
log "Fetching available TPU zones in region '$TPU_REGION'..."
ZONES_RAW=$(gcloud compute zones list --filter="name ~ ^$TPU_REGION" --format="value(name)")
# Convert to array with trimmed values
ZONES=()
while IFS= read -r zone; do
    zone=$(echo "$zone" | tr -d '[:space:]')
    if [[ -n "$zone" ]]; then
        ZONES+=("$zone")
    fi
done <<< "$ZONES_RAW"

if [[ ${#ZONES[@]} -eq 0 ]]; then
    log "ERROR: No zones found in region '$TPU_REGION'"
    exit 1
fi

log "Found zones in region '$TPU_REGION':"
for zone in "${ZONES[@]}"; do
    log "- $zone"
done

# Check each zone for the specified TPU type
FOUND_ZONE=""

for zone in "${ZONES[@]}"; do
    log "Checking zone '$zone' for TPU type '$TPU_TYPE'..."
    
    # Create a temporary file for TPU output
    TPU_OUTPUT_FILE=$(mktemp)
    
    # Get TPU types available in this zone
    gcloud compute tpus tpu-vm accelerator-types list \
        --zone="$zone" \
        --project="$PROJECT_ID" > "$TPU_OUTPUT_FILE" 2>/dev/null
    
    if [[ $? -ne 0 ]]; then
        log "⚠ Unable to get TPU types for zone '$zone'"
        rm "$TPU_OUTPUT_FILE"
        continue
    fi
    
    # Check if file has content
    if [[ ! -s "$TPU_OUTPUT_FILE" ]]; then
        log "⚠ No TPU types returned for zone '$zone'"
        rm "$TPU_OUTPUT_FILE"
        continue
    fi
    
    # Display available types
    log "Available TPU types in zone '$zone':"
    while IFS= read -r line; do
        if [[ "$line" == ACCELERATOR_TYPE:* ]]; then
            TPU=$(echo "$line" | sed 's/ACCELERATOR_TYPE:[[:space:]]*//')
            TPU=$(echo "$TPU" | tr -d '[:space:]')
            log "  - $TPU"
            
            # Check for our target TPU type
            if [[ "$TPU" == "$TPU_TYPE" ]]; then
                log "✓ TPU type '$TPU_TYPE' found in zone '$zone'!"
                FOUND_ZONE="$zone"
            fi
        fi
    done < "$TPU_OUTPUT_FILE"
    
    # Clean up
    rm "$TPU_OUTPUT_FILE"
    
    # Exit loop if we found a matching zone
    if [[ -n "$FOUND_ZONE" ]]; then
        break
    else
        log "× TPU type '$TPU_TYPE' not found in zone '$zone'"
    fi
done

# Update .env file directly with the found zone
if [[ -n "$FOUND_ZONE" ]]; then
    log "Successfully found matching zone: $FOUND_ZONE"
    # Update TPU_ZONE in the .env file
    ENV_FILE="$SCRIPT_DIR/../source/.env"
    
    # Check if .env file is writable
    if [[ ! -w "$ENV_FILE" ]]; then
        log "ERROR: Cannot write to .env file. Please check permissions."
        exit 1
    fi
    
    # Different sed syntax for macOS vs Linux/Windows
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS requires an empty string for -i
        sed -i '' "s/^TPU_ZONE=.*$/TPU_ZONE=$FOUND_ZONE/" "$ENV_FILE"
    else
        # Linux/Windows doesn't need an empty string
        sed -i "s/^TPU_ZONE=.*$/TPU_ZONE=$FOUND_ZONE/" "$ENV_FILE"
    fi
    
    # Verify the .env file was updated correctly
    if grep -q "^TPU_ZONE=$FOUND_ZONE" "$ENV_FILE"; then
        log "Updated .env file with TPU_ZONE=$FOUND_ZONE"
    else
        log "WARNING: Failed to update TPU_ZONE in .env file. Please manually set TPU_ZONE=$FOUND_ZONE"
    fi
else
    log "ERROR: TPU type '$TPU_TYPE' not found in any zone in region '$TPU_REGION'"
    log "Please check if the TPU type is correct and available in the region."
    exit 1
fi

log "Zone availability check completed successfully"