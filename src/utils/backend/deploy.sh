#!/bin/bash
set -e

# Get the directory of this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../../" && pwd)"

# Load environment variables from source
source "$PROJECT_DIR/source/.env"

# Echo with timestamp
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Check for required environment variables
required_vars=("PROJECT_ID" "SERVICE_ACCOUNT_JSON")
for var in "${required_vars[@]}"; do
  if [ -z "${!var}" ]; then
    log "ERROR: Required environment variable $var is not set"
    exit 1
  fi
done

# Authenticate with Google Cloud
log "Authenticating with Google Cloud..."
if [ -f "$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON" ]; then
  gcloud auth activate-service-account --key-file="$PROJECT_DIR/source/$SERVICE_ACCOUNT_JSON"
else
  log "ERROR: Service account JSON file not found: $SERVICE_ACCOUNT_JSON"
  exit 1
fi

# Set project
gcloud config set project $PROJECT_ID

# Configure Docker to use GCR
log "Configuring Docker for gcr.io..."
gcloud auth configure-docker gcr.io

# Build the container
log "Building container image..."
IMAGE_NAME="gcr.io/${PROJECT_ID}/tae-backend:v1"
docker build -t $IMAGE_NAME .

# Push the image to Container Registry
log "Pushing image to Container Registry..."
docker push $IMAGE_NAME

# Deploy to Cloud Run
log "Deploying to Cloud Run..."
gcloud run deploy tae-backend \
  --image $IMAGE_NAME \
  --platform managed \
  --region $BUCKET_REGION \
  --allow-unauthenticated \
  --set-env-vars="PROJECT_ID=${PROJECT_ID},BUCKET_NAME=${BUCKET_NAME},TPU_NAME=${TPU_NAME},TPU_ZONE=${TPU_ZONE}" \
  --service-account $SERVICE_ACCOUNT_EMAIL

log "Deployment completed successfully!"

# Output the service URL
SERVICE_URL=$(gcloud run services describe tae-backend --platform managed --region $BUCKET_REGION --format 'value(status.url)')
log "Service is available at: $SERVICE_URL" 