#!/bin/bash
set -e

# Start TensorBoard in the background
mkdir -p /app/tensorboard
tensorboard --logdir=/app/tensorboard --host=0.0.0.0 --port=6006 &

# Set up the environment for TPU access
echo "Setting up TPU environment..."

# Set the GCP credentials if available
if [ -f /app/keys/service-account.json ]; then
    echo "Setting up service account authentication..."
    export GOOGLE_APPLICATION_CREDENTIALS=/app/keys/service-account.json
    gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS
fi

# Display TPU device info
echo "Checking TPU device..."
python -c "import torch_xla.core.xla_model as xm; print(xm.xla_device())"

# Run the command provided in CMD
echo "Starting application..."
exec "$@"