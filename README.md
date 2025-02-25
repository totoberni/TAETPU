# Google Cloud TPU PyTorch Hello World

This repository contains a complete setup for running PyTorch on Google Cloud TPU VMs. It demonstrates how to set up a TPU VM, install PyTorch with XLA support, and run a simple test script that validates TPU functionality.

## Project Structure
```
.
├── .gitattributes          # Git attributes configuration
├── .gitignore              # Git ignore configuration
├── README.md               # Project documentation
└── tpu_hello_world/
    ├── .env                # Environment variables and configuration
    ├── main.py             # Main Python script for TPU execution
    ├── check_zones.sh      # Script to find available TPU zones
    ├── run_main.sh         # Script to run main.py on TPU
    ├── setup_bucket.sh     # Script to create GCS bucket
    ├── setup_tpu.sh        # Script to create TPU VM and install PyTorch
    ├── teardown_bucket.sh  # Script to delete GCS bucket
    └── teardown_tpu.sh     # Script to delete TPU VM
```

## File Descriptions

- `.env`: Contains all configuration variables including project ID, TPU specifications, and service account details
- `main.py`: PyTorch script that verifies TPU connectivity and performs basic tensor operations
- `check_zones.sh`: Finds available TPU zones in your configured region and updates the .env file automatically
- `run_main.sh`: Handles the deployment and execution of main.py on the TPU VM with proper environment variables
- `setup_bucket.sh`: Creates a Google Cloud Storage bucket for TPU-related storage
- `setup_tpu.sh`: Provisions and configures the TPU VM, including PyTorch installation with the latest dependencies
- `teardown_bucket.sh`: Safely deletes the GCS bucket and its contents
- `teardown_tpu.sh`: Deletes the TPU VM instance

## Configuration

Before running the scripts, update the `.env` file with your specific settings:

```bash
# Project Configuration
PROJECT_ID=your-project-id
TPU_REGION=europe-west4
TPU_ZONE=europe-west4-a
BUCKET_REGION=europe-west4
TPU_NAME=your-tpu-name
TPU_TYPE=v2-8
TPU_RUNTIME_VERSION=tpu-vm-tf-2.15.0

# Cloud Storage
BUCKET_NAME=your-bucket-name

# Service Account details
SERVICE_ACCOUNT_JSON=your-service-account.json
SERVICE_ACCOUNT_EMAIL=your-service-account@your-project.iam.gserviceaccount.com

# PyTorch Configuration
INSTALL_PYTORCH=true

# Optional TPU initialization arguments
# LIBTPU_INIT_ARGS=--xla_jf_conv_full_precision=true
```

## Setup and Workflow

### 1. Preparation

Make all scripts executable:
```bash
chmod +x tpu_hello_world/*.sh
```

### 2. Find Available TPU Zone

The first step is to find a zone where your desired TPU type is available:

```bash
# Change to the tpu_hello_world directory
cd tpu_hello_world

# Run the zone checker
./check_zones.sh
```

This will automatically update your `.env` file with the correct `TPU_ZONE` value.

### 3. Set Up Google Cloud Storage

Create a bucket for storing TPU-related files:

```bash
./setup_bucket.sh
```

### 4. Set Up TPU VM

Create and configure the TPU VM, including PyTorch installation:

```bash
./setup_tpu.sh
```

### 5. Run the Hello World Example

Execute the PyTorch script on the TPU VM:

```bash
./run_main.sh
```

### 6. Clean Up Resources

When you're done:

```bash
# Delete the TPU VM
./teardown_tpu.sh

# Delete the GCS bucket (will prompt for confirmation)
./teardown_bucket.sh
```

## Prerequisites

- Google Cloud SDK installed and configured
- Service account with necessary permissions:
  - Compute Admin
  - Storage Admin
  - Service Account User
- Python 3.7 or higher
- Google Cloud project with TPU API enabled

## Environment Variables

When running PyTorch code on the TPU VM, the following environment variables are automatically set:

```bash
# Added to LD_LIBRARY_PATH to ensure TPU libraries are properly found
LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$HOME/.local/lib/

# Specifies that we're using a TPU device
PJRT_DEVICE=TPU

# Disables debug mode for better performance
PT_XLA_DEBUG=0

# Enables PyTorch XLA integration
USE_TORCH=ON

# Optional: For workloads with very large allocations where tcmalloc might cause slowdowns
# unset LD_PRELOAD
```

## PyTorch TPU Installation

The setup script installs the following components:

- System dependencies: `libopenblas-dev`, `libomp5`
- Python dependencies: `mkl`, `mkl-include`, `numpy`
- PyTorch with XLA support: `torch`, `torch_xla[tpu]~=2.5.0`

The installation includes a workaround for setuptools version issues that can occur during installation.

## Error Handling

All scripts include:
- Timestamp-based logging
- Error trapping and reporting
- Resource existence checking
- Proper cleanup on failure
- Environment variable validation

## Troubleshooting

Common issues and solutions:

1. **TPU Creation Fails**
   - Verify quota availability in your region
   - Check if the TPU type is available in selected zone (use `check_zones.sh`)
   - Ensure TPU API is enabled

2. **PyTorch Installation Issues**
   - If you encounter `InvalidRequirement` errors, the setup script will automatically downgrade setuptools
   - Verify internet connectivity on TPU VM
   - Check compatibility between PyTorch and TPU runtime versions
   - Ensure sufficient disk space

3. **Authentication Errors**
   - Verify service account JSON file path
   - Check service account permissions
   - Ensure Google Cloud SDK is properly configured

4. **Performance Issues**
   - For models with large allocations, try uncommenting the `unset LD_PRELOAD` line in `run_main.sh`
   - Check TPU utilization with the Cloud Monitoring dashboard

## Security Notes

- Service account JSON files are automatically ignored by git
- Bucket access is configured with uniform bucket-level access
- All scripts verify credential existence before execution
- Service account authentication is only attempted if credentials are provided

## Additional Resources

For more information, refer to:
- [Google Cloud TPU Documentation](https://cloud.google.com/tpu/docs)
- [PyTorch XLA Documentation](https://pytorch.org/xla/)
- [TPU Performance Guide](https://cloud.google.com/tpu/docs/performance-guide)