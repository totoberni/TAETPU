#!/bin/bash

# --- DETERMINE SCRIPT AND PROJECT DIRECTORIES ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- IMPORT COMMON FUNCTIONS ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

# --- MAIN SCRIPT ---
init_script 'GCS bucket setup'
ENV_FILE="$PROJECT_DIR/source/.env"
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" "BUCKET_NAME" "BUCKET_REGION" "BUCKET_DATRAIN" "BUCKET_TENSORBOARD" || exit 1

# Display configuration
display_config "PROJECT_ID" "BUCKET_NAME" "BUCKET_REGION" "BUCKET_DATRAIN" "BUCKET_TENSORBOARD"

# Set up authentication
setup_auth

# Check if bucket exists
if gsutil ls -b "gs://$BUCKET_NAME" &> /dev/null; then
    log "Bucket 'gs://$BUCKET_NAME' already exists."
else
    # Create the bucket with specified settings
    log "Creating GCS bucket: gs://$BUCKET_NAME..."
    gsutil mb -p "$PROJECT_ID" -l "$BUCKET_REGION" -b on "gs://$BUCKET_NAME"
    
    log "GCS bucket creation completed in region $BUCKET_REGION"
fi

# Parse GCS path to extract bucket and directory components
# and validate that they match our expected bucket
parse_gcs_path() {
    local full_path="$1"
    local expected_bucket="$2"
    
    # Validate format (gs://bucket/path)
    if [[ ! "$full_path" =~ ^gs://([^/]+)/(.*)$ ]]; then
        log_error "Invalid GCS path format: $full_path"
        echo ""
        return 1
    fi
    
    local bucket="${BASH_REMATCH[1]}"
    local path="${BASH_REMATCH[2]}"
    
    # Check if the bucket in the path matches our expected bucket
    if [[ "$bucket" != "$expected_bucket" ]]; then
        log_warning "Bucket in path ($bucket) doesn't match expected bucket ($expected_bucket)"
    fi
    
    # Ensure path ends with a slash for directory semantics
    if [[ -n "$path" && "${path: -1}" != "/" ]]; then
        path="${path}/"
    fi
    
    echo "$path"
}

# Create necessary directories in the bucket
create_directory() {
    local dir_path="$1"
    local description="$2"
    
    # Skip if the directory path is empty
    if [[ -z "$dir_path" ]]; then
        log "Skipping creation of empty directory path"
        return
    fi
    
    log "Creating $description directory: $dir_path"
    
    # In GCS, directories are virtual and created when files are added
    # We create an empty placeholder file to establish the directory
    echo "" | gsutil cp - "gs://$BUCKET_NAME/$dir_path.directory_marker"
    
    # List the newly created "directory"
    gsutil ls -la "gs://$BUCKET_NAME/$dir_path"
    
    log "$description directory created successfully"
}

# Extract directory paths from the environment variables
log "Parsing directories from environment variables..."
TRAINING_DATA_DIR=$(parse_gcs_path "$BUCKET_DATRAIN" "$BUCKET_NAME")
TENSORBOARD_DIR=$(parse_gcs_path "$BUCKET_TENSORBOARD" "$BUCKET_NAME")

log "Setting up directories in bucket 'gs://$BUCKET_NAME'..."
log "Training data path: $TRAINING_DATA_DIR"
log "TensorBoard logs path: $TENSORBOARD_DIR"

create_directory "$TRAINING_DATA_DIR" "Training data"
create_directory "$TENSORBOARD_DIR" "TensorBoard logs"

log_success "GCS Bucket Setup Complete. Bucket 'gs://$BUCKET_NAME' is ready with all required directories."
log ""
log "To verify bucket configuration, run:"
log "$PROJECT_DIR/src/utils/verify.sh --bucket"