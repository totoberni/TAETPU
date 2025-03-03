#!/bin/bash
set -e

# Print TensorFlow version and TPU information
echo "TensorFlow version: $(python -c 'import tensorflow as tf; print(tf.__version__)')"
echo "Checking TPU configuration..."

# Make sure TPU environment variables are set
export PJRT_DEVICE=${PJRT_DEVICE:-TPU}
export NEXT_PLUGGABLE_DEVICE_USE_C_API=${NEXT_PLUGGABLE_DEVICE_USE_C_API:-true}
export TF_PLUGGABLE_DEVICE_LIBRARY_PATH=${TF_PLUGGABLE_DEVICE_LIBRARY_PATH:-/lib/libtpu.so}
export TF_XLA_FLAGS=${TF_XLA_FLAGS:-"--tf_xla_enable_xla_devices --tf_xla_cpu_global_jit"}
export XRT_TPU_CONFIG=${XRT_TPU_CONFIG:-"localservice;0;localhost:51011"}
export ALLOW_MULTIPLE_LIBTPU_LOAD=${ALLOW_MULTIPLE_LIBTPU_LOAD:-1}

# Run a simple TPU check
python -c "
import tensorflow as tf
print('TensorFlow version:', tf.__version__)
print('Devices available:')
for device in tf.config.list_physical_devices():
    print(f'  {device.name} - {device.device_type}')
try:
    print('Looking for TPU devices...')
    tpu_devices = tf.config.list_logical_devices('TPU')
    print(f'Found {len(tpu_devices)} TPU devices')
    for device in tpu_devices:
        print(f'  {device.name}')
    if len(tpu_devices) > 0:
        print('TPU is available!')
except Exception as e:
    print(f'Error checking TPU: {e}')
"

# Execute the provided command or start a shell
if [ $# -eq 0 ]; then
  echo "No command provided, starting bash shell"
  exec /bin/bash
else
  echo "Executing command: $@"
  exec "$@"
fi 