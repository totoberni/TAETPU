#!/bin/bash

# --- DETERMINE SCRIPT AND PROJECT DIRECTORIES ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# --- IMPORT COMMON FUNCTIONS ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

# --- MAIN SCRIPT ---
init_script "TPU VM version compatibility check"
ENV_FILE="$PROJECT_DIR/source/.env"
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_TYPE" "TF_VERSION" || exit 1

# Display configuration
display_config "PROJECT_ID" "TPU_ZONE" "TPU_TYPE" "TF_VERSION"

# Set up authentication
setup_auth

# Get all available TPU VM versions for the specified zone
log "Fetching available TPU VM versions in zone '$TPU_ZONE'..."
VERSIONS_RAW=$(gcloud compute tpus tpu-vm versions list --zone="$TPU_ZONE" --project="$PROJECT_ID" 2>/dev/null)

if [[ $? -ne 0 ]]; then
    log_error "Failed to retrieve TPU VM versions. Please check your credentials and try again."
    exit 1
fi

# Create a temporary file for TPU version output
TPU_VERSION_FILE=$(mktemp)
echo "$VERSIONS_RAW" > "$TPU_VERSION_FILE"

# Check if file has content
if [[ ! -s "$TPU_VERSION_FILE" ]]; then
    log_error "No TPU VM versions returned for zone '$TPU_ZONE'"
    rm "$TPU_VERSION_FILE"
    exit 1
fi

# Extract TF major version (e.g., 2.18 from 2.18.0)
TF_MAJOR_VERSION=$(echo "$TF_VERSION" | sed -E 's/([0-9]+\.[0-9]+)\.[0-9]+/\1/')

# Check for compatible versions based on TPU type and TF version
log "Looking for compatible TPU VM versions for TF $TF_VERSION with TPU type $TPU_TYPE..."

# Array to store matching TPU VM versions
MATCHING_VERSIONS=()

# Read the output file line by line
while IFS= read -r line; do
    if [[ "$line" =~ RUNTIME_VERSION:\ *(.*) ]]; then
        VERSION="${BASH_REMATCH[1]}"

        # Look for versions that match our TF version and PJRT runtime
        if [[ "$VERSION" == *"tf-$TF_MAJOR_VERSION"*"-pjrt"* ]]; then
            MATCHING_VERSIONS+=("$VERSION")
            log "Found potential matching version: $VERSION"
        fi
    fi
done < "$TPU_VERSION_FILE"

# Clean up temp file
rm "$TPU_VERSION_FILE"

# Check if we found any matching versions
if [[ ${#MATCHING_VERSIONS[@]} -eq 0 ]]; then
    log_error "No matching TPU VM versions found for TensorFlow $TF_VERSION with PJRT runtime"
    log_error "Please check if TensorFlow $TF_VERSION is supported in zone $TPU_ZONE"
    exit 1
fi

# Determine the best version based on TPU type
log "Determining optimal version for TPU type $TPU_TYPE..."
SELECTED_VERSION=""

# For v2-8 and v3-8, we need versions that support v5p-and-below
if [[ "$TPU_TYPE" == "v2-8" || "$TPU_TYPE" == "v3-8" ]]; then
    for version in "${MATCHING_VERSIONS[@]}"; do
        if [[ "$version" == *"v5p-and-below"* ]]; then
            SELECTED_VERSION="$version"
            log_success "Found optimal version for TPU $TPU_TYPE: $SELECTED_VERSION"
            break
        fi
    done
# For newer TPU types (v4, v5e, v5p, v6)
elif [[ "$TPU_TYPE" == "v4-8" || "$TPU_TYPE" == "v4-16" || "$TPU_TYPE" == "v4-32" ]]; then
    for version in "${MATCHING_VERSIONS[@]}"; do
        if [[ "$version" == *"v5p-and-below"* ]]; then
            SELECTED_VERSION="$version"
            log_success "Found optimal version for TPU $TPU_TYPE: $SELECTED_VERSION"
            break
        fi
    done
# For newer TPU types (v5e, v5p, v6)
elif [[ "$TPU_TYPE" == *"v5"* || "$TPU_TYPE" == *"v6"* ]]; then
    for version in "${MATCHING_VERSIONS[@]}"; do
        if [[ "$version" == *"v5e-and-v6"* || "$version" == *"v5e"* || "$version" == *"v6"* ]]; then
            SELECTED_VERSION="$version"
            log_success "Found optimal version for TPU $TPU_TYPE: $SELECTED_VERSION"
            break
        fi
    done
fi

# If we couldn't find a specific match, use the first one that has PJRT
if [[ -z "$SELECTED_VERSION" && ${#MATCHING_VERSIONS[@]} -gt 0 ]]; then
    SELECTED_VERSION="${MATCHING_VERSIONS[0]}"
    log_warning "No specific match found for TPU type $TPU_TYPE, using: $SELECTED_VERSION"
fi

# If we found a compatible version, update the .env file
if [[ -n "$SELECTED_VERSION" ]]; then
    log_success "Successfully found matching version: $SELECTED_VERSION"

    # Check if .env file is writable
    if [[ ! -w "$ENV_FILE" ]]; then
        log_error "Cannot write to .env file. Please check permissions."
        exit 1
    fi

    # Create a backup before modifying
    cp "$ENV_FILE" "${ENV_FILE}.bak"
    log "Created backup at ${ENV_FILE}.bak"

    # Different sed syntax for macOS vs Linux/Windows
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS requires an empty string for -i
        # Account for possible carriage return at end of line with \r\?
        sed -i '' "s/^TPU_VM_VERSION=.*\r\?$/TPU_VM_VERSION=$SELECTED_VERSION/" "$ENV_FILE"
    else
        # Linux/Windows doesn't need an empty string
        # Account for possible carriage return at end of line with \r\?
        sed -i "s/^TPU_VM_VERSION=.*\r\?$/TPU_VM_VERSION=$SELECTED_VERSION/" "$ENV_FILE"
    fi

    # More reliable verification by directly checking for the presence of the value
    # This approach doesn't care about line endings
    if cat "$ENV_FILE" | tr -d '\r' | grep -q "TPU_VM_VERSION=$SELECTED_VERSION"; then
        log_success "Updated .env file with TPU_VM_VERSION=$SELECTED_VERSION"
    else
        log_warning "Failed to verify TPU_VM_VERSION update in .env file. Please manually set TPU_VM_VERSION=$SELECTED_VERSION"
        log "Note: The file may still have been updated correctly despite this warning."
    fi
else
    log_error "Could not determine an appropriate version for TPU $TPU_TYPE with TF $TF_VERSION"
    log "Available versions were: ${MATCHING_VERSIONS[*]}"
    exit 1
fi

log_success "TPU VM version compatibility check completed successfully"