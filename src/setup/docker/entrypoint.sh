#!/bin/bash

echo "TensorFlow TPU container started"
echo "TensorFlow version: $(python -c "import tensorflow as tf; print(tf.__version__)")"
echo "TPU cores available: $(python -c "import tensorflow as tf; print(len(tf.config.list_logical_devices(\"TPU\")))")"
echo "Running in $(pwd)"

# Keep container running if no command is provided
if [ $# -eq 0 ]; then
  echo "No command provided, keeping container alive..."
  tail -f /dev/null
else
  # Execute the provided command
  exec "$@"
fi 