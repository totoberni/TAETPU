#!/bin/bash
# entrypoint.sh - Entry point script for the Docker container.
# This script initializes the environment and then executes the command provided as CMD.

set -e

# Import common logging functions
source "/app/utils/common_logging.sh"

# Use common logging functions
init_script "Container Startup"
log "Starting container with TPU configuration"
log "- PJRT_DEVICE: ${PJRT_DEVICE}"
log "- XLA_USE_BF16: ${XLA_USE_BF16}"
log "- Flask Environment: ${FLASK_ENV}"

# Configure TPU environment with sensible defaults
configure_tpu_env

# Verify TPU accessibility by attempting to print the TPU device
if python -c "import torch_xla.core.xla_model as xm; print('TPU device:', xm.xla_device())" >/dev/null 2>&1; then
  log_success "TPU is accessible."
else
  log_warning "Warning: TPU not accessible. Please check your configuration."
fi

# Log command execution
log "Executing command: $@"

# Execute the main process specified in CMD (e.g., the Flask server)
exec "$@"
