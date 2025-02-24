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

# Set the project and zone
gcloud config set project $PROJECT_ID
gcloud config set compute/zone $ZONE

# Authenticate with the service account
gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"

# Create the TPU VM
gcloud compute tpus tpu-vm create $TPU_NAME \
    --zone=$ZONE \
    --accelerator-type=$TPU_TYPE \
    --version=$RUNTIME_VERSION

# Create a GCS bucket (if it doesn't already exist)
gsutil mb -p $PROJECT_ID -l $ZONE gs://$BUCKET_NAME

# Copy the main.py to the TPU VM
gcloud compute tpus tpu-vm scp main.py $TPU_NAME: --zone=$ZONE

# Connect to the TPU VM via SSH (in the background)
gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$ZONE --command="bash" &

# Wait for SSH to be fully ready
sleep 30

# Install optimum-tpu
gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$ZONE --command="pip install optimum-tpu -f https://storage.googleapis.com/libtpu-releases/index.html"

# Set PJRT_DEVICE environment variable
gcloud compute tpus tpu-vm ssh $TPU_NAME --zone=$ZONE --command="export PJRT_DEVICE=TPU"

echo "TPU Setup Complete. TPU '$TPU_NAME' is ready." 