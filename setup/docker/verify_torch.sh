#!/bin/bash

# --- HELPER FUNCTIONS ---
log() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] $1"
}

# --- MAIN SCRIPT ---
log 'Verifying PyTorch and torch_xla installation...'

# Check PyTorch version
python3 -c "import torch; print(f'PyTorch version: {torch.__version__}')"

# Check torch_xla installation and available devices
python3 -c "import torch_xla.core.xla_model as xm; print(f'XLA Devices: {xm.get_xla_supported_devices()}')"

log 'Verification complete.' 