#!/bin/bash
set -e

# Start TensorBoard in the background
mkdir -p /app/tensorboard
tensorboard --logdir=/app/tensorboard --host=0.0.0.0 --port=6006 &

# Set up authentication if credentials exist
if [ -f /app/keys/service-account.json ]; then
    export GOOGLE_APPLICATION_CREDENTIALS=/app/keys/service-account.json
    gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS
fi

# Verify TPU device
python -c "import torch_xla.core.xla_model as xm; print('TPU device found:', xm.xla_device())" || echo "Warning: TPU device not detected"

# Execute the command
exec "$@"