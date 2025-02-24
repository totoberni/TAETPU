#!/bin/bash

# Load environment variables from .env file
source .env

# Set the service account credentials
export GOOGLE_APPLICATION_CREDENTIALS="../$SERVICE_ACCOUNT_JSON"

# Verify the credentials file exists
if [ ! -f "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    echo "Error: Service account JSON file not found at $GOOGLE_APPLICATION_CREDENTIALS"
    exit 1
fi

# Authenticate with the service account
gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"

# Delete the TPU VM
gcloud compute tpus tpu-vm delete $TPU_NAME \
    --zone=$ZONE \
    --quiet

# Optional: Delete the GCS bucket (uncomment if needed)
# gsutil rm -r gs://$BUCKET_NAME

echo "TPU Teardown Complete. TPU '$TPU_NAME' has been deleted." 