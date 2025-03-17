#!/bin/bash
set -e

# Ensure all required directories exist (in case they weren't created in the Dockerfile)
echo "Verifying directory structure..."
mkdir -p /app/mount/src /app/mount/data /app/mount/models /app/mount/logs /app/tensorboard /app/keys

# Log directory setup - will be used for external log collection
echo "Setting up logging directory at /app/logs..."
chmod -R 755 /app/mount/logs

# Start TensorBoard in the background
tensorboard --logdir=/app/tensorboard --host=0.0.0.0 --port=6006 &
TB_PID=$!

# Set up authentication if credentials exist
if [ -f /app/keys/service-account.json ]; then
    export GOOGLE_APPLICATION_CREDENTIALS=/app/keys/service-account.json
    gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS
    echo "Authenticated with Google Cloud using service account"
fi

# Verify TPU device
echo "Verifying TPU device..."
python -c "import torch_xla.core.xla_model as xm; print('TPU device found:', xm.xla_device())" || {
    echo "Warning: TPU device not detected, check PJRT_DEVICE environment variable"
    echo "Current PJRT_DEVICE: $PJRT_DEVICE"
}

# Print TPU device information
python -c "
import torch_xla.core.xla_model as xm
import torch_xla.runtime as xr
print('XLA Runtime information:')
print(f'- World size: {xr.world_size()}')
print(f'- Process index: {xr.process_index()}')
print(f'- Global device count: {xr.global_device_count()}')
" || echo "Failed to get TPU runtime information"

# Handle signals to properly clean up
cleanup() {
    echo "Shutting down services..."
    kill $TB_PID 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# Execute the command
echo "Starting command: $@"
exec "$@"