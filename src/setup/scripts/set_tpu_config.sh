#!/bin/bash
# determine_tpu_config.sh
# Merged script to dynamically determine and update .env variables:
#   - TPU_ZONE based on available zones for TPU_REGION and TPU_TYPE
#   - TPU_VM_VERSION based on the selected TPU_ZONE, TF_VERSION and TPU_TYPE

# --- DETERMINE SCRIPT AND PROJECT DIRECTORIES ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# --- IMPORT COMMON FUNCTIONS ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

# --- INITIALIZE SCRIPT ---
init_script "TPU Configuration Auto-Detection"
ENV_FILE="$PROJECT_DIR/source/.env"
load_env_vars "$ENV_FILE" || exit 1

# Validate required environment variables
check_env_vars "PROJECT_ID" "TPU_REGION" "TPU_TYPE" "TF_VERSION" || exit 1

# Display current configuration
display_config "PROJECT_ID" "TPU_REGION" "TPU_TYPE" "TF_VERSION"

# Set up authentication
setup_auth

#############################
#   STEP 1: Determine TPU_ZONE
#############################
log "Fetching available TPU zones in region '$TPU_REGION'..."
ZONES_RAW=$(gcloud compute zones list --filter="name ~ ^$TPU_REGION" --format="value(name)")
ZONES=()
while IFS= read -r zone; do
    zone=$(echo "$zone" | tr -d '[:space:]')
    if [[ -n "$zone" ]]; then
        ZONES+=("$zone")
    fi
done <<< "$ZONES_RAW"

if [[ ${#ZONES[@]} -eq 0 ]]; then
    log_error "No zones found in region '$TPU_REGION'"
    exit 1
fi

log "Found zones in region '$TPU_REGION':"
for zone in "${ZONES[@]}"; do
    log "- $zone"
done

FOUND_ZONE=""
for zone in "${ZONES[@]}"; do
    log "Checking zone '$zone' for TPU type '$TPU_TYPE'..."
    
    TPU_OUTPUT_FILE=$(mktemp)
    gcloud compute tpus tpu-vm accelerator-types list --zone="$zone" --project="$PROJECT_ID" > "$TPU_OUTPUT_FILE" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        log "⚠ Unable to get TPU types for zone '$zone'"
        rm "$TPU_OUTPUT_FILE"
        continue
    fi
    
    if [[ ! -s "$TPU_OUTPUT_FILE" ]]; then
        log "⚠ No TPU types returned for zone '$zone'"
        rm "$TPU_OUTPUT_FILE"
        continue
    fi

    log "Available TPU types in zone '$zone':"
    while IFS= read -r line; do
        if [[ "$line" == ACCELERATOR_TYPE:* ]]; then
            TPU=$(echo "$line" | sed 's/ACCELERATOR_TYPE:[[:space:]]*//')
            TPU=$(echo "$TPU" | tr -d '[:space:]')
            log "  - $TPU"
            if [[ "$TPU" == "$TPU_TYPE" ]]; then
                log "✓ TPU type '$TPU_TYPE' found in zone '$zone'!"
                FOUND_ZONE="$zone"
                break
            fi
        fi
    done < "$TPU_OUTPUT_FILE"
    rm "$TPU_OUTPUT_FILE"
    
    if [[ -n "$FOUND_ZONE" ]]; then
        break
    else
        log "× TPU type '$TPU_TYPE' not found in zone '$zone'"
    fi
done

if [[ -z "$FOUND_ZONE" ]]; then
    log_error "TPU type '$TPU_TYPE' not found in any zone in region '$TPU_REGION'"
    exit 1
fi

log "Successfully found matching zone: $FOUND_ZONE"
# Update .env with the found TPU_ZONE
if [[ ! -w "$ENV_FILE" ]]; then
    log_error "Cannot write to .env file. Please check permissions."
    exit 1
fi
if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "s/^TPU_ZONE=.*$/TPU_ZONE=$FOUND_ZONE/" "$ENV_FILE"
else
    sed -i "s/^TPU_ZONE=.*$/TPU_ZONE=$FOUND_ZONE/" "$ENV_FILE"
fi
if grep -q "^TPU_ZONE=$FOUND_ZONE" "$ENV_FILE"; then
    log "Updated .env file with TPU_ZONE=$FOUND_ZONE"
else
    log_warning "Failed to update TPU_ZONE in .env file. Please manually set TPU_ZONE=$FOUND_ZONE"
fi
export TPU_ZONE="$FOUND_ZONE"

#############################
#   STEP 2: Determine TPU_VM_VERSION
#############################
log "Fetching available TPU VM versions in zone '$TPU_ZONE'..."
VERSIONS_RAW=$(gcloud compute tpus tpu-vm versions list --zone="$TPU_ZONE" --project="$PROJECT_ID" 2>/dev/null)
if [[ $? -ne 0 ]]; then
    log_error "Failed to retrieve TPU VM versions. Please check your credentials and try again."
    exit 1
fi

TPU_VERSION_FILE=$(mktemp)
echo "$VERSIONS_RAW" > "$TPU_VERSION_FILE"
if [[ ! -s "$TPU_VERSION_FILE" ]]; then
    log_error "No TPU VM versions returned for zone '$TPU_ZONE'"
    rm "$TPU_VERSION_FILE"
    exit 1
fi

# Extract TF major version (e.g., 2.18 from 2.18.0)
TF_MAJOR_VERSION=$(echo "$TF_VERSION" | sed -E 's/([0-9]+\.[0-9]+)\.[0-9]+/\1/')
log "Looking for compatible TPU VM versions for TF $TF_VERSION with TPU type $TPU_TYPE..."

MATCHING_VERSIONS=()
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
rm "$TPU_VERSION_FILE"

if [[ ${#MATCHING_VERSIONS[@]} -eq 0 ]]; then
    log_error "No matching TPU VM versions found for TensorFlow $TF_VERSION with PJRT runtime"
    exit 1
fi

log "Determining optimal version for TPU type $TPU_TYPE..."
SELECTED_VERSION=""
# For older TPU types (v2-8 or v3-8)
if [[ "$TPU_TYPE" == "v2-8" || "$TPU_TYPE" == "v3-8" ]]; then
    for version in "${MATCHING_VERSIONS[@]}"; do
        if [[ "$version" == *"v5p-and-below"* ]]; then
            SELECTED_VERSION="$version"
            log_success "Found optimal version for TPU $TPU_TYPE: $SELECTED_VERSION"
            break
        fi
    done
# For v4 types (v4-8, v4-16, v4-32)
elif [[ "$TPU_TYPE" == "v4-8" || "$TPU_TYPE" == "v4-16" || "$TPU_TYPE" == "v4-32" ]]; then
    for version in "${MATCHING_VERSIONS[@]}"; do
        if [[ "$version" == *"v5p-and-below"* ]]; then
            SELECTED_VERSION="$version"
            log_success "Found optimal version for TPU $TPU_TYPE: $SELECTED_VERSION"
            break
        fi
    done
# For newer TPU types (v5 and v6)
elif [[ "$TPU_TYPE" == *"v5"* || "$TPU_TYPE" == *"v6"* ]]; then
    for version in "${MATCHING_VERSIONS[@]}"; do
        if [[ "$version" == *"v5e-and-v6"* || "$version" == *"v5e"* || "$version" == *"v6"* ]]; then
            SELECTED_VERSION="$version"
            log_success "Found optimal version for TPU $TPU_TYPE: $SELECTED_VERSION"
            break
        fi
    done
fi

if [[ -z "$SELECTED_VERSION" && ${#MATCHING_VERSIONS[@]} -gt 0 ]]; then
    SELECTED_VERSION="${MATCHING_VERSIONS[0]}"
    log_warning "No specific match found for TPU type $TPU_TYPE, using: $SELECTED_VERSION"
fi

if [[ -n "$SELECTED_VERSION" ]]; then
    log_success "Successfully found matching TPU VM version: $SELECTED_VERSION"
    if [[ ! -w "$ENV_FILE" ]]; then
        log_error "Cannot write to .env file. Please check permissions."
        exit 1
    fi
    cp "$ENV_FILE" "${ENV_FILE}.bak"
    log "Created backup at ${ENV_FILE}.bak"
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s/^TPU_VM_VERSION=.*$/TPU_VM_VERSION=$SELECTED_VERSION/" "$ENV_FILE"
    else
        sed -i "s/^TPU_VM_VERSION=.*$/TPU_VM_VERSION=$SELECTED_VERSION/" "$ENV_FILE"
    fi
    if grep -q "^TPU_VM_VERSION=$SELECTED_VERSION" "$ENV_FILE"; then
        log_success "Updated .env file with TPU_VM_VERSION=$SELECTED_VERSION"
    else
        log_warning "Failed to verify TPU_VM_VERSION update in .env file. Please manually set TPU_VM_VERSION=$SELECTED_VERSION"
    fi
else
    log_error "Could not determine an appropriate version for TPU $TPU_TYPE with TF $TF_VERSION"
    log "Available versions were: ${MATCHING_VERSIONS[*]}"
    exit 1
fi

log_success "TPU configuration auto-detection completed successfully"
display_config "PROJECT_ID" "TPU_REGION" "TPU_TYPE" "TPU_ZONE" "TPU_VM_VERSION" "TF_VERSION"
exit 0
