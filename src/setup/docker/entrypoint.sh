#!/bin/bash
set -e

# Print information about the environment
echo "================================================================"
echo "TensorFlow Docker Container for TPU"
echo "================================================================"
echo "TensorFlow version: $(python -c 'import tensorflow as tf; print(tf.__version__)')"
echo "Python version: $(python --version)"
echo "================================================================"
echo "Checking TPU configuration..."

# Make sure TPU environment variables are set
export PJRT_DEVICE=${PJRT_DEVICE:-TPU}
export NEXT_PLUGGABLE_DEVICE_USE_C_API=${NEXT_PLUGGABLE_DEVICE_USE_C_API:-true}
export TF_PLUGGABLE_DEVICE_LIBRARY_PATH=${TF_PLUGGABLE_DEVICE_LIBRARY_PATH:-/lib/libtpu.so}
export TF_XLA_FLAGS=${TF_XLA_FLAGS:-"--tf_xla_enable_xla_devices --tf_xla_cpu_global_jit"}
export XRT_TPU_CONFIG=${XRT_TPU_CONFIG:-"localservice;0;localhost:51011"}
export ALLOW_MULTIPLE_LIBTPU_LOAD=${ALLOW_MULTIPLE_LIBTPU_LOAD:-1}

# Check if libtpu.so exists
if [ -f "/lib/libtpu.so" ]; then
    echo "libtpu.so found at /lib/libtpu.so"
else
    echo "WARNING: libtpu.so not found at /lib/libtpu.so"
fi

# Run a simple TPU check
python -c "
import tensorflow as tf
print('TensorFlow version:', tf.__version__)
print('Devices available:')
for device in tf.config.list_physical_devices():
    print(f'  {device.name} - {device.device_type}')
try:
    print('Looking for TPU devices...')
    resolver = tf.distribute.cluster_resolver.TPUClusterResolver()
    print(f'TPU detected: {resolver.cluster_spec()}')
    tf.config.experimental_connect_to_cluster(resolver)
    tf.tpu.experimental.initialize_tpu_system(resolver)
    print('TPU devices initialized successfully')
    tpu_strategy = tf.distribute.TPUStrategy(resolver)
    print(f'TPU strategy created with {tpu_strategy.num_replicas_in_sync} replicas')
except Exception as e:
    print(f'Note: TPU might not be accessible in the build environment: {e}')
    print('This is expected during build. TPU will be available when running in the TPU VM.')
"

# Execute the provided command or start a shell
if [ $# -eq 0 ]; then
  echo "No command provided, starting bash shell"
  exec /bin/bash
else
  echo "Executing command: $@"
  exec "$@"
fi 