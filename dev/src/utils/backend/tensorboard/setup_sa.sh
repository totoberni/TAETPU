# src/backend/tensorboard/setup_sa.sh
#!/bin/bash

# Get script directory for absolute path references
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Import common functions
source "$PROJECT_DIR/src/utils/common_logging.sh"

# Main script
init_script 'TensorBoard service account setup'
ENV_FILE="$PROJECT_DIR/source/.env"
load_env_vars "$ENV_FILE"

# Validate required environment variables
check_env_vars "PROJECT_ID" "BUCKET_NAME" || exit 1

# Create service account name (using consistent naming)
SA_NAME="tensorboard-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# Display configuration
display_config "PROJECT_ID" "BUCKET_NAME"
log "- Service Account: $SA_EMAIL"

# Set up authentication
setup_auth

# Check if service account already exists
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" &> /dev/null; then
  log "Service account $SA_EMAIL already exists."
else
  # Create service account
  log "Creating service account $SA_EMAIL..."
  gcloud iam service-accounts create "$SA_NAME" \
    --project="$PROJECT_ID" \
    --display-name="TensorBoard Service Account"
  
  log_success "Service account created successfully"
fi

# Grant GCS access permissions
log "Granting GCS access permissions..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/storage.objectViewer"

log_success "Service account setup complete."