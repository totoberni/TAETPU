# backend/deploy.sh
#!/bin/bash

# Get script directory for absolute path references
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load both environment files
source "$PROJECT_DIR/source/.env"
source "$PROJECT_DIR/backend/.env"

# Print configuration
echo "Deploying TensorBoard backend to Cloud Run"
echo "Project ID: $PROJECT_ID"
echo "Service Name: $TENSORBOARD_SERVICE_NAME"
echo "Region: $CLOUD_RUN_REGION"
echo "Service Account: $SERVICE_ACCOUNT_EMAIL"

# Build and push the Docker image
gcloud builds submit "$SCRIPT_DIR/docker" \
  --tag "gcr.io/$PROJECT_ID/$TENSORBOARD_SERVICE_NAME:latest" \
  --project="$PROJECT_ID"

# Deploy to Cloud Run
gcloud run deploy "$TENSORBOARD_SERVICE_NAME" \
  --image="gcr.io/$PROJECT_ID/$TENSORBOARD_SERVICE_NAME:latest" \
  --platform=managed \
  --region="$CLOUD_RUN_REGION" \
  --service-account="$SERVICE_ACCOUNT_EMAIL" \
  --allow-unauthenticated \
  --set-env-vars="BUCKET_NAME=$BUCKET_NAME,TENSORBOARD_LOG_DIR=$TENSORBOARD_LOG_DIR,TENSORBOARD_PORT=$TENSORBOARD_PORT,TENSORBOARD_HOST=$TENSORBOARD_HOST,SERVER_PORT=$SERVER_PORT,API_ENABLED=$API_ENABLED" \
  --project="$PROJECT_ID"

# Get the service URL
SERVICE_URL=$(gcloud run services describe "$TENSORBOARD_SERVICE_NAME" \
  --platform=managed \
  --region="$CLOUD_RUN_REGION" \
  --project="$PROJECT_ID" \
  --format="value(status.url)")

echo "TensorBoard service deployed successfully at: $SERVICE_URL"