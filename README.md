# Transformer Ablation Experiment on Google Cloud TPU (TAETPU)

This repository provides a framework for conducting Transformer model ablation experiments on Google Cloud TPUs, enabling systematic study of how different components affect performance and behavior.

## Quick Start

```bash
# 1. Configure your environment (from template)
cp source/.env.template source/.env
vim source/.env  # Edit with your project details

# 2. Verify your environment setup
./src/utils/verify.sh --env-only     # Basic environment variable check
./src/utils/verify.sh --check-infra  # Also check GCP infrastructure 

# 3. Setup Bucket
./src/setup/scripts/setup_bucket.sh

# 4. Set up infrastructure
./src/setup/scripts/setup_image.sh   # Build Docker image
./src/setup/scripts/setup_tpu.sh     # Create TPU VM

# 5. Verify TPU hardware access
./src/utils/verify.sh --check-hardware  # Verify TPU driver and device
./src/utils/verify.sh --full            # Run complete verification with TensorFlow

# 6. Run example code
./dev/mgt/mount_run_scrap.sh example.py
```

## Detailed Setup Guide

### 1. Environment Configuration

The first step is to set up your environment variables:

```bash
# Copy the template file
cp source/.env.template source/.env

# Edit the file with your specific GCP project details
vim source/.env
```

Key environment variables to configure:
- `PROJECT_ID`: Your Google Cloud project ID
- `TPU_REGION` and `TPU_ZONE`: Region and zone where your TPU will be created
- `TPU_NAME`: Name for your TPU VM instance
- `TPU_TYPE`: TPU hardware type (e.g., v2-8, v3-8)
- `TPU_VM_VERSION`: TPU software version
- `BUCKET_NAME`: GCS bucket for storing data and logs
- `SERVICE_ACCOUNT_JSON`: Path to your service account key file (if using service account auth)

### 2. Environment Verification

Before proceeding, verify your environment configuration:

```bash
# Basic verification of environment variables
./src/utils/verify.sh --env-only
```

This checks that all required variables are set in your `.env` file and displays your current configuration.

For a more comprehensive check that also verifies your GCP infrastructure:

```bash
# Check GCP project, TPU VM (if exists), GCS bucket, and Docker image
./src/utils/verify.sh --check-infra
```

### 3. GCS Bucket Setup

Set up a Google Cloud Storage bucket for storing training data, model checkpoints, and TensorBoard logs:

```bash
./src/setup/scripts/setup_bucket.sh
```

This script:
- Creates a new GCS bucket with the name specified in your `.env` file
- Sets up appropriate access permissions
- Creates standard directories for training data and TensorBoard logs

### 4. Infrastructure Setup

#### 4.1 Docker Image Setup

Build a Docker image optimized for TPU development:

```bash
./src/setup/scripts/setup_image.sh
```

This script:
- Creates a Docker image based on TensorFlow 2.18.0
- Installs required Python dependencies from `src/setup/docker/requirements.txt`
- Configures TPU environment variables
- Pushes the image to Google Container Registry (GCR)

Advanced options:
```bash
# Build image with TPU driver included (useful for distribution)
./src/setup/scripts/setup_image.sh --bake-driver

# Build image but don't push to GCR
./src/setup/scripts/setup_image.sh --no-push

# Force rebuild even if image exists
./src/setup/scripts/setup_image.sh --force-rebuild

# Use a custom Dockerfile
./src/setup/scripts/setup_image.sh --dockerfile=/path/to/custom/Dockerfile
```

#### 4.2 TPU VM Setup

Create and configure a TPU VM instance:

```bash
./src/setup/scripts/setup_tpu.sh
```

This script:
- Creates a new TPU VM with the specified name, type, and version
- Sets up Docker permissions on the VM
- Configures authentication for GCR access
- Sets up TPU environment variables in the VM's `.bashrc`
- Verifies TPU driver and device accessibility
- Pulls the Docker image to the VM

The script automatically:
- Checks if the TPU VM already exists
- Configures Docker permissions for the user
- Sets up service account authentication if provided
- Configures TPU environment variables with sensible defaults
- Verifies the TPU environment is working correctly

### 5. TPU Hardware Verification

After setting up the TPU VM, verify that the TPU hardware is accessible:

```bash
# Verify TPU driver and device accessibility
./src/utils/verify.sh --check-hardware
```

This performs several checks:
- Verifies TPU VM exists and is in READY state
- Checks for TPU driver (libtpu.so) on the VM
- Verifies TPU device (/dev/accel0) is accessible

For a comprehensive verification including a TensorFlow test:

```bash
# Run complete verification with TensorFlow test
./src/utils/verify.sh --full
```

This additionally:
- Creates a TensorFlow test script on the VM
- Runs a simple computation on the TPU
- Verifies TensorFlow can access and use the TPU

### 6. Running Code on TPU

The repository provides several ways to run your code on the TPU VM:

#### Option 1: Quick Development (One-step)

```bash
# Mount, run, and clean up in one command
./dev/mgt/mount_run_scrap.sh your_script.py [script_args]
```

This:
- Copies your script to the TPU VM
- Runs it inside the Docker container with TPU access
- Removes the script from the VM when done

#### Option 2: Manual Steps

```bash
# 1. Mount file to TPU VM
./dev/mgt/mount.sh your_script.py

# 2. Run file on TPU VM
./dev/mgt/run.sh your_script.py [script_args]

# 3. Clean up when done
./dev/mgt/scrap.sh your_script.py
```

This gives you more control over each step of the process.

#### Option 3: Continuous Development

```bash
# Watch for code changes and sync automatically
./dev/mgt/synch.sh --watch --utils

# Sync and restart container
./dev/mgt/synch.sh --restart
```

This is useful for active development, automatically syncing code changes to the TPU VM.

## Project Structure

The codebase has been streamlined for better maintainability following DRY principles:

```
TAETPU/
├── dev/                            # Development environment
│   ├── mgt/                        # Development management scripts
│   │   ├── mount.sh                # Mount files to TPU VM
│   │   ├── run.sh                  # Run files on TPU VM
│   │   ├── scrap.sh                # Remove files from TPU VM
│   │   ├── mount_run_scrap.sh      # Combined workflow script
│   │   ├── synch.sh                # File synchronization with watch capability
│   │   └── verify_tpu.sh           # TPU verification wrapper (uses unified verify.sh)
│   └── src/                        # Development source code and examples
│
├── src/                            # Main source code
│   ├── utils/                      # Unified utility modules
│   │   ├── common_logging.sh       # Enhanced shared logging and utilities
│   │   └── verify.sh               # Unified verification system
│   ├── setup/                      # Setup scripts and configurations
│   │   ├── docker/                 # Docker related files
│   │   │   ├── Dockerfile          # TPU-optimized Docker image
│   │   │   ├── entrypoint.sh       # Container entrypoint using shared config
│   │   │   ├── tpu_config.sh       # Shared TPU Docker configuration 
│   │   │   └── requirements.txt    # Python dependencies
│   │   └── scripts/                # Infrastructure setup scripts
│   │       ├── setup_image.sh      # Build and push Docker image
│   │       ├── setup_tpu.sh        # Create TPU VM
│   │       └── verify.sh           # Symlink to unified verification
│   ├── teardown/                   # Resource cleanup scripts
│   │   ├── teardown_tpu.sh         # Delete TPU VM
│   │   ├── teardown_image.sh       # Delete Docker images
│   │   └── teardown_bucket.sh      # Delete GCS bucket
│
└── source/                         # Project source and configuration
    ├── .env                        # Environment configuration (created from template)
    └── .env.template               # Template for environment configuration
```

## TPU Environment Variables

The system ensures TPU environment variables are consistently set with sensible defaults:

| Variable | Purpose | Default Value |
|----------|---------|-------|
| `TPU_NAME` | Identifies TPU device | `local` |
| `TPU_LOAD_LIBRARY` | Prevents redundant driver loading | `0` |
| `TF_PLUGGABLE_DEVICE_LIBRARY_PATH` | TPU driver location | `/lib/libtpu.so` |
| `PJRT_DEVICE` | Specifies PJRT device type | `TPU` |
| `NEXT_PLUGGABLE_DEVICE_USE_C_API` | Enables C API for PJRT | `true` |
| `XLA_USE_BF16` | Enables BF16 precision | `1` |

These variables are automatically set in:
- The Docker container environment
- The TPU VM's `.bashrc` file
- The Docker run command when executing scripts

## TensorFlow TPU Best Practices

```python
# 1. Use TPUStrategy for distributed training
import tensorflow as tf

strategy = tf.distribute.TPUStrategy()
with strategy.scope():
    model = tf.keras.Sequential([...])
    model.compile(optimizer="adam", loss="mse")
    model.fit(dataset, epochs=10)

# 2. Use tf.function for best performance
@tf.function
def training_step(inputs):
    # Computation here
    return result

strategy.run(training_step, args=(next(iterator),))
```

## Monitoring

The repository includes a monitoring system for TPU workloads:

```bash
# Start monitoring
./dev/mgt/monitor_tpu.sh start

# Start monitoring with dashboard
./dev/mgt/monitor_tpu.sh start --dashboard

# Stop monitoring
./dev/mgt/monitor_tpu.sh stop
```

## Troubleshooting

### Common TPU Issues

1. **TPU Driver not found**
   - Run verification to automatically locate the driver: `./src/utils/verify.sh --check-hardware`
   - The system will now search for the driver in standard locations and update your configuration

2. **TPU Hardware not accessible**
   - Run full verification: `./src/utils/verify.sh --full`
   - Ensure `--privileged` and `--device=/dev/accel0` are used with Docker

3. **Out of Memory Errors**
   - Reduce batch size
   - Use mixed precision (BF16)
   - Ensure `XLA_USE_BF16=1` is set (now done automatically)

### Using the Unified Verification System

The unified verification system provides detailed diagnostics for common issues:

```bash
# Check environment variables only
./src/utils/verify.sh --env-only

# Check GCP infrastructure (project, TPU VM, bucket, Docker image)
./src/utils/verify.sh --check-infra

# Also verify TPU hardware accessibility
./src/utils/verify.sh --check-hardware

# Run full verification including TensorFlow test
./src/utils/verify.sh --full
```

## Clean Up Resources

When you're done with your experiments, clean up your resources to avoid unnecessary charges:

```bash
# Delete TPU VM
./src/teardown/teardown_tpu.sh

# Delete Docker images
./src/teardown/teardown_image.sh

# Delete GCS bucket (use with caution - deletes all data)
./src/teardown/teardown_bucket.sh
```

The teardown scripts:
- Prompt for confirmation before deleting resources
- Check if resources exist before attempting deletion
- Provide detailed output of the deletion process

## Project Purpose

This project allows you to systematically study Transformer architecture components through ablation studies:
- Remove/modify attention heads, layers, feed-forward networks, etc.
- Measure performance impact on different tasks
- Optimize for specific hardware (particularly TPUs)
- Identify minimum viable architectures for specific performance thresholds

## Recent Improvements

1. **DRY Code Refactorization**:
   - Created a unified verification system that replaces multiple redundant scripts
   - Centralized common functions in enhanced `common_logging.sh` library
   - Standardized Docker configuration with `tpu_config.sh`
   - Eliminated duplicate functionality across scripts
   - Simplified development workflow with better diagnostics

2. **Enhanced TPU Environment Handling**:
   - Added automatic TPU driver discovery across the system
   - Standardized TPU environment variables with sensible defaults
   - Improved verification process with tiered levels (env-only, infra, hardware, full)
   - Integrated TPU verification with Docker container setup

3. **Improved Docker Integration**:
   - Added centralized TPU configuration for Docker containers
   - Enhanced Docker entrypoint script with better verification
   - Standardized Docker command generation across different scripts
   - Reduced duplicate code between scripts

4. **Streamlined Development Workflow**:
   - Added comprehensive verification options with clear error messages
   - Enhanced error handling with automatic detection of common issues
   - Improved directory and path detection for more robust script execution
   - Added timing information and better execution status tracking

## Resources

- [TensorFlow TPU Guide](https://www.tensorflow.org/guide/tpu)
- [Google Cloud TPU Documentation](https://cloud.google.com/tpu/docs)
- [TPU Performance Guide](https://cloud.google.com/tpu/docs/performance-guide)
