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
./src/setup/scripts/setup_tpu.sh --create  # Create TPU VM

# 5. Verify TPU hardware access
./src/utils/verify.sh --check-hardware  # Verify TPU driver and device
./src/utils/verify.sh --full            # Run complete verification with TensorFlow

# 6. Run example code
./dev/mgt/mount_run_scrap.sh example.py
```

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
│
└── source/                         # Project source and configuration
    ├── .env                        # Environment configuration (created from template)
    └── .env.template               # Template for environment configuration
```

## Setup & Configuration

### Prerequisites

- Google Cloud project with TPU API enabled
- Docker installed on your development machine
- Google Cloud SDK configured

### Environment Variables

All required environment variables are now automatically verified by the unified verification system:

```bash
# Run verification with increasing levels of detail
./src/utils/verify.sh --env-only       # Check environment variables
./src/utils/verify.sh --check-infra    # Also verify GCP resources
./src/utils/verify.sh --check-hardware # Also verify TPU hardware access 
./src/utils/verify.sh --full           # Run complete verification with TensorFlow
```

### Docker Image Setup

The Docker image setup has been enhanced to use a consistent TPU configuration:

```bash
# Build standard image (mounts TPU driver at runtime)
./src/setup/scripts/setup_image.sh

# Build image with TPU driver included (useful for distribution)
./src/setup/scripts/setup_image.sh --bake-driver

# Build image but don't push to GCR
./src/setup/scripts/setup_image.sh --no-push
```

### TPU VM Setup

The TPU VM setup has been enhanced with better verification:

```bash
# Create a new TPU VM
./src/setup/scripts/setup_tpu.sh --create

# Force recreate an existing TPU VM
./src/setup/scripts/setup_tpu.sh --force-recreate

# Create TPU VM and skip hardware verification
./src/setup/scripts/setup_tpu.sh --create --skip-verify

# Create TPU VM and set up monitoring
./src/setup/scripts/setup_tpu.sh --create --setup-monitoring
```

### TPU Environment Variables

The system now ensures TPU environment variables are consistently set with sensible defaults:

| Variable | Purpose | Default Value |
|----------|---------|-------|
| `TPU_NAME` | Identifies TPU device | `local` |
| `TPU_LOAD_LIBRARY` | Prevents redundant driver loading | `0` |
| `TF_PLUGGABLE_DEVICE_LIBRARY_PATH` | TPU driver location | `/lib/libtpu.so` |
| `PJRT_DEVICE` | Specifies PJRT device type | `TPU` |
| `NEXT_PLUGGABLE_DEVICE_USE_C_API` | Enables C API for PJRT | `true` |
| `XLA_USE_BF16` | Enables BF16 precision | `1` |

## Development Workflow

### Option 1: Quick Development (One-step)

```bash
# Mount, run, and clean up in one command
./dev/mgt/mount_run_scrap.sh your_script.py [script_args]
```

### Option 2: Manual Steps

```bash
# 1. Mount file to TPU VM
./dev/mgt/mount.sh your_script.py

# 2. Run file on TPU VM
./dev/mgt/run.sh your_script.py [script_args]

# 3. Clean up when done
./dev/mgt/scrap.sh your_script.py
```

### Option 3: Continuous Development

```bash
# Watch for code changes and sync automatically
./dev/mgt/synch.sh --watch --utils

# Sync and restart container
./dev/mgt/synch.sh --restart
```

### Verification of TPU Access

The unified verification system makes it easier to validate your TPU environment:

```bash
# Quick verification
./src/utils/verify.sh --check-hardware

# Comprehensive verification including TensorFlow test
./src/utils/verify.sh --full
```

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

```bash
# Delete TPU VM
./src/teardown/teardown_tpu.sh

# Delete Docker images
./src/teardown/teardown_image.sh
```

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
