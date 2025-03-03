# src/backend/tensorboard/start.sh
#!/bin/bash

# Load environment variables if .env exists
if [ -f ".env" ]; then
  export $(grep -v '^#' .env | xargs)
fi

# Print configuration
echo "Starting TensorBoard visualization server"
echo "========================================" 
echo "BUCKET_NAME: ${BUCKET_NAME}"
echo "TENSORBOARD_LOG_DIR: ${TENSORBOARD_LOG_DIR}"
echo "PORT: ${PORT}"
echo "TENSORBOARD_PORT: ${TENSORBOARD_PORT}"
echo "TENSORBOARD_HOST: ${TENSORBOARD_HOST}"
echo "API_ENABLED: ${API_ENABLED}"

# Build the complete GCS path
GCS_LOG_PATH="gs://${BUCKET_NAME}/${TENSORBOARD_LOG_DIR}"
echo "Reading TensorBoard logs from: ${GCS_LOG_PATH}"

# Start TensorBoard (background)
if [ "$API_ENABLED" = "true" ]; then
  echo "Starting TensorBoard in background with API server..."
  tensorboard --logdir="${GCS_LOG_PATH}" --bind_all --port=${TENSORBOARD_PORT} &
  TB_PID=$!
  
  # Start the API server (foreground)
  echo "Starting API server on port ${PORT}..."
  exec gunicorn --bind=${TENSORBOARD_HOST}:${PORT} server:app
else
  # Start just TensorBoard (foreground)
  echo "Starting TensorBoard without API server..."
  exec tensorboard --logdir="${GCS_LOG_PATH}" --bind_all --port=${PORT}
fi