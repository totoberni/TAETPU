#!/bin/bash
# TPU Docker Entrypoint Script
# This script sets the proper TPU environment variables,
# verifies that the mounted driver file and device nodes are available,
# and configures the environment (including creating a symlink to the TPU driver if needed).

echo "=== TPU Docker Entrypoint ==="

# Set environment variables (or use the values already provided)
export TPU_NAME=${TPU_NAME:-local}
export TPU_LOAD_LIBRARY=${TPU_LOAD_LIBRARY:-0}
export PJRT_DEVICE=${PJRT_DEVICE:-TPU}
export XLA_USE_BF16=${XLA_USE_BF16:-1}
export NEXT_PLUGGABLE_DEVICE_USE_C_API=${NEXT_PLUGGABLE_DEVICE_USE_C_API:-true}
export TF_PLUGGABLE_DEVICE_LIBRARY_PATH=${TF_PLUGGABLE_DEVICE_LIBRARY_PATH:-/lib/libtpu.so}

echo "TPU Environment:"
echo "  TPU_NAME=$TPU_NAME"
echo "  TPU_LOAD_LIBRARY=$TPU_LOAD_LIBRARY"
echo "  PJRT_DEVICE=$PJRT_DEVICE"
echo "  XLA_USE_BF16=$XLA_USE_BF16"
echo "  NEXT_PLUGGABLE_DEVICE_USE_C_API=$NEXT_PLUGGABLE_DEVICE_USE_C_API"
echo "  TF_PLUGGABLE_DEVICE_LIBRARY_PATH=$TF_PLUGGABLE_DEVICE_LIBRARY_PATH"

# Verify that the TPU driver file exists
if [[ ! -f "$TF_PLUGGABLE_DEVICE_LIBRARY_PATH" ]]; then
    echo "WARNING: TPU driver not found at $TF_PLUGGABLE_DEVICE_LIBRARY_PATH"
    for loc in /lib/libtpu.so /usr/lib/libtpu.so /usr/local/lib/libtpu.so; do
        if [[ -f "$loc" ]]; then
            echo "Found TPU driver at $loc"
            export TF_PLUGGABLE_DEVICE_LIBRARY_PATH="$loc"
            break
        fi
    done
    if [[ ! -f "$TF_PLUGGABLE_DEVICE_LIBRARY_PATH" ]]; then
        echo "ERROR: TPU driver (libtpu.so) not found. Exiting."
        exit 1
    fi
fi

# Check for TPU device node (/dev/accel0)
if [[ ! -e "/dev/accel0" ]]; then
    echo "WARNING: TPU device (/dev/accel0) not found. Ensure you run the container with --privileged and --device=/dev/accel0."
else
    echo "TPU device (/dev/accel0) is available."
fi

# Create a symlink if the driver is not at the default location
if [[ "$TF_PLUGGABLE_DEVICE_LIBRARY_PATH" != "/lib/libtpu.so" ]]; then
    echo "Creating symlink: ln -sf $TF_PLUGGABLE_DEVICE_LIBRARY_PATH /lib/libtpu.so"
    ln -sf "$TF_PLUGGABLE_DEVICE_LIBRARY_PATH" /lib/libtpu.so
fi

echo "=== TPU environment configuration complete ==="
echo "=== Executing command: $@ ==="
exec "$@"
