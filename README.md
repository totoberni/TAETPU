# Transformer Ablation Experiment on Google Cloud TPU (TAETPU)

This repository contains a comprehensive framework for conducting Transformer model ablation experiments on Google Cloud TPUs. It provides the necessary infrastructure to set up, run, and analyze experiments that examine the impact of various Transformer architecture components on model performance.

## Project Purpose

The goal of this project is to systematically study how different components of Transformer architectures affect performance, efficiency, and behavior. Through ablation studies, we can gain insights into:

1. The relative importance of various Transformer mechanisms (attention heads, feed-forward networks, layer normalization, etc.)
2. How architectural choices impact performance on different tasks
3. Potential optimizations for specific use cases and hardware (particularly TPUs)
4. The minimum viable architecture needed for specific performance thresholds

These insights are valuable for both developing more efficient models and deepening our theoretical understanding of why Transformers work so well.

## What Are Ablation Studies?

Ablation studies involve systematically removing, replacing, or modifying components of a model to understand their contribution to the overall performance. In the context of Transformers, we might:

- Remove individual attention heads
- Vary the number of layers
- Modify the feed-forward network size
- Replace layer normalization with alternatives
- Adjust positional encoding schemes

By measuring the impact of these changes, we can identify which components are most critical and which might be simplified or removed with minimal performance loss.

## Why TPUs?

Transformer models are computationally intensive to train and evaluate. Google Cloud TPUs provide:

1. Specialized hardware designed for the matrix operations common in Transformers
2. Significant acceleration compared to CPU/GPU for certain workloads
3. Scalability for large models and datasets
4. Cost efficiencies for long-running experiments

This repository provides a complete environment for deploying and running these experiments on TPU infrastructure.

## Enhanced Monitoring & Logging

This framework includes comprehensive monitoring and logging capabilities specifically designed for TPU-based experiments:

### Key Features

1. **TPU Performance Metrics**
   - Track compilation time, execution time, and memory usage
   - Monitor TPU utilization and device health
   - Capture XLA operations and optimization statistics

2. **Experiment Tracking**
   - Compatible with TensorBoard and Weights & Biases
   - Automatic metrics collection and visualization
   - Experiment comparisons and history tracking

3. **Profiling Tools**
   - Memory profiling to identify leaks and inefficiencies
   - Operation timing for bottleneck identification
   - Flame graphs for CPU/Python performance analysis

4. **Dashboard Visualization**
   - Generate HTML reports with interactive visualizations

### TPU Monitoring Scripts

The repository includes dedicated scripts for monitoring TPU performance and resource utilization:

```bash
# Start monitoring a TPU VM
./dev/mgt/monitor_tpu.sh start YOUR_TPU_NAME

# Start monitoring a TPU VM and specific Python process
./dev/mgt/monitor_tpu.sh start YOUR_TPU_NAME PYTHON_PID

# Stop monitoring
./dev/mgt/monitor_tpu.sh stop
```

These monitoring scripts provide:
- Continuous tracking of TPU state and health
- Collection of TPU utilization metrics
- Flame graph generation for Python processes

```python
# Initialize logging and monitoring
from utils.tpu_logging import setup_logger, TPUMetricsLogger
from utils.profiling import ModelProfiler
from utils.experiment import ExperimentTracker

# Set up logging with file output
logger = setup_logger(log_level="INFO", log_file="logs/experiment.log")

# Create experiment tracker
experiment = ExperimentTracker(
    experiment_name="transformer_ablation", 
    use_tensorboard=True,
    use_wandb=False  # Set to True to enable W&B
)

# Profile model performance
profiler = ModelProfiler(model, log_dir="logs/profiler")
profiler.profile_memory("Before training")

# Log TPU metrics during training
tpu_logger = TPUMetricsLogger()
tpu_logger.log_metrics(step=current_step)
```

## Project Structure

The project has been organized with a standardized configuration system that ensures all components use a centralized YAML configuration with environment variable support.

```
.
├── .gitattributes                # Git attributes configuration
├── .gitignore                    # Git ignore configuration
├── README.md                     # Project documentation (this file)
├── dev/                          # Development environment for rapid iteration
│   ├── src/                      # Development code to run on TPU
│   │   ├── example.py            # Example file for TPU code development
│   │   ├── example_monitoring.py # Example using monitoring capabilities 
│   │   ├── start_monitoring.py   # Script to start/stop monitoring system
│   │   ├── start_monitoring.sh   # Shell wrapper for monitoring system
│   │   ├── run_example.sh        # Script to run example with monitoring
│   │   └── utils/                # Utilities for development code
│   │       ├── experiment.py     # Experiment tracking utilities
│   │       ├── profiling.py      # TPU profiling utilities
│   │       ├── api/              # API integration utilities
│   │       ├── dashboards/       # Dashboard visualization components
│   │       ├── monitors/         # Monitoring system components
│   │       └── logging/          # Logging and configuration utilities
│   │           ├── cls_logging.py # Logging implementation
│   │           ├── config_loader.py # Configuration loading system
│   │           └── log_config.yaml # Centralized YAML configuration
│   ├── mgt/                      # Management scripts for development (all self-contained)
│   │   ├── mount.sh              # Script to mount files to TPU VM
│   │   ├── run.sh                # Script to execute files on TPU VM
│   │   ├── scrap.sh              # Script to remove files from TPU VM
│   │   ├── mount_run_scrap.sh    # All-in-one script to mount, run, and clean up
│   │   ├── synch.sh              # Enhanced script for syncing and watching code changes
│   │   └── monitor_tpu.sh        # Self-contained TPU monitoring script
│   └── README.md                 # Documentation for the development workflow
├── src/                          # Source code for the project
│   ├── setup/                    # Setup scripts and configuration
│   │   ├── scripts/              # Scripts for setting up the environment
│   │   │   ├── check_zones.sh    # Script to find available TPU zones
│   │   │   ├── setup_bucket.sh   # Script to create GCS bucket
│   │   │   ├── setup_image.sh    # Script to build and push Docker image to GCR
│   │   │   ├── setup_tpu.sh      # Script to create TPU VM and pull Docker image
│   │   │   ├── verify_setup.sh   # Script to verify TPU setup and PyTorch/XLA
│   │   │   └── verify.py         # Python verification utility for TPU setup
│   │   └── docker/               # Docker configuration
│   │       ├── Dockerfile        # Docker image definition
│   │       └── requirements.txt  # Python dependencies
│   ├── teardown/                 # Scripts for resource cleanup
│   │   ├── teardown_bucket.sh    # Script to delete GCS bucket
│   │   ├── teardown_image.sh     # Script to clean up Docker images locally and in GCR
│   │   └── teardown_tpu.sh       # Script to delete TPU VM
│   └── utils/                    # Shared utilities
│       └── common_logging.sh     # Common bash utilities and logging functions
└── source/                       # Configuration and credential files
    ├── .env                      # Environment variables and configuration
    └── service-account.json      # Service account key (replace with your own)
```

## Recent Improvements

The codebase has been refactored with the following improvements:

1. **Standardized Configuration System**:
   - Centralized YAML configuration file (`log_config.yaml`) for all settings
   - Environment variable support with defaults using `${VAR_NAME:-default}` syntax
   - Dynamic resolution of environment variables to adapt to changes in system configuration
   - Simplified configuration loading without complex fallback mechanisms

2. **Absolute Path References**: All scripts now use absolute path resolution to determine their location, allowing them to be called from any directory in the project.

3. **Centralized Logging**: Most scripts utilize a common logging framework from `common.sh` for consistent output styling and error handling.

4. **Environment Variable Validation**: Scripts now properly validate required environment variables before execution.

5. **Enhanced Error Handling**: Better error reporting and graceful failures when prerequisites aren't met.

6. **Self-Contained Development Scripts**: The scripts in `dev/mgt` are now self-contained with their own logging functions, avoiding cross-directory dependencies.

7. **Improved Security**: Scripts properly check for and use service account credentials when available.

8. **Consistent Configuration**: All scripts use the same approach to loading and validating configuration.

## Setting Up the Environment

Before running transformer ablation experiments, you'll need to set up the Google Cloud TPU environment. The following instructions walk you through this process.

### Configuration

Before running the scripts, create a `source/.env` file with your specific settings by copying from the template:

```bash
# Copy the template (don't edit the template directly)
cp source/.env.template source/.env

# Then edit your .env file with your specific settings
nano source/.env  # or use your preferred editor
```

Your `.env` file should contain the following settings (the template provides placeholders):

```bash
# Project Configuration
PROJECT_ID=your-project-id
TPU_REGION=europe-west4
TPU_ZONE=europe-west4-a
BUCKET_REGION=europe-west4
TPU_NAME=your-tpu-name
TPU_TYPE=v2-8
# Note: The TPU runtime version is now fixed to tpu-ubuntu2204-base in the setup script

# Cloud Storage
BUCKET_NAME=your-bucket-name

# Service Account details
SERVICE_ACCOUNT_JSON=your-service-account.json
SERVICE_ACCOUNT_EMAIL=your-service-account@your-project.iam.gserviceaccount.com

# PyTorch Configuration
INSTALL_PYTORCH=true
```

> **IMPORTANT SECURITY NOTE:** The `.env` file and service account key files are automatically excluded from version control by `.gitignore`. Never commit these files to the repository as they contain sensitive information.

### Security Best Practices

To protect your Google Cloud credentials:

1. **Never commit service account keys**: Keep your service account JSON files out of version control
2. **Use `.env.template` for documentation**: Only commit the template, not your actual `.env` file
3. **Restrict service account permissions**: Follow the principle of least privilege
4. **Rotate keys regularly**: Create new service account keys periodically
5. **Monitor for exposed credentials**: Set up alerts for potential key exposure
6. **Private repositories**: Keep code with credential handling in private repositories

If you think a key may have been exposed:
1. Immediately revoke the key in Google Cloud Console
2. Generate a new key and update your local `.env` file
3. Check commit history to ensure no credentials were accidentally committed

### Complete Workflow for TPU Setup and Execution

Follow these steps in order to set up your TPU environment and prepare for experiments:

#### 1. Preparation

Make all scripts executable:
```bash
chmod +x src/setup/scripts/*.sh
chmod +x src/teardown/*.sh
chmod +x dev/mgt/*.sh
```

#### 2. Check for Available TPU Zones

First, find a zone where your desired TPU type is available:

```bash
# Run the zone checker (can be run from any directory)
./src/setup/scripts/check_zones.sh
```

This script will:
- Check all zones in your configured TPU_REGION
- Search for availability of your specified TPU_TYPE
- Automatically update your .env file with the correct TPU_ZONE

#### 3. Set Up Google Cloud Storage Bucket

Create a bucket for storing experiment data, model checkpoints, and logs:

```bash
./src/setup/scripts/setup_bucket.sh
```

#### 4. Build and Push the Docker Image

Build your Docker image and push it to Google Container Registry:

```bash
./src/setup/scripts/setup_image.sh
```

#### 5. Set Up TPU VM and Pull Docker Image

Create the TPU VM and pull the Docker image:

```bash
./src/setup/scripts/setup_tpu.sh
```

#### 6. Verify TPU Environment

Verify that PyTorch and XLA are properly installed and can access the TPU:

```bash
./src/setup/scripts/verify_setup.sh
```

### TPU Monitoring Tools

The framework includes dedicated monitoring scripts for TPU performance:

```bash
# Start TPU monitoring in the background (run from any directory)
./dev/mgt/monitor_tpu.sh start YOUR_TPU_NAME

# Start TPU monitoring and also monitor a Python process
./dev/mgt/monitor_tpu.sh start YOUR_TPU_NAME PYTHON_PID

# Stop all monitoring services
./dev/mgt/monitor_tpu.sh stop
```

These monitoring scripts will generate logs and performance data in the `logs/` directory, which can be analyzed using the dashboard utilities.

### Development Workflow

For rapid development and testing without rebuilding the Docker image, see the `dev/README.md` for detailed instructions. Here's a quick overview:

```bash
# Mount and run the example monitoring script (can be run from any directory)
./dev/mgt/mount_run_scrap.sh example_monitoring.py

# Or use individual commands for more control
./dev/mgt/mount.sh example_monitoring.py
./dev/mgt/run.sh example_monitoring.py
./dev/mgt/scrap.sh example_monitoring.py
```

The development workflow allows you to:
1. Create or modify Python files in the `dev/src` directory
2. Mount them to the TPU VM using the `mount.sh` script
3. Execute them on the TPU VM using the `run.sh` script
4. Clean up using the `scrap.sh` script when done

### Clean Up Resources When Finished

When you're done, clean up resources in this order:

```bash
# Delete the TPU VM
./src/teardown/teardown_tpu.sh

# Delete the Docker images (local and GCR)
./src/teardown/teardown_image.sh

# Delete the GCS bucket (will prompt for confirmation)
./src/teardown/teardown_bucket.sh
```

## CI/CD Development Workflow

This project implements a simplified CI/CD workflow for TPU development, allowing for rapid iteration without needing to rebuild Docker images for every code change.

### Development vs. Production

**Important Note**: The `dev/` folder and its contents are designed for development only and **will not be included in the production deployment**. During development, code can be quickly synced and tested; for production, a clean Docker image is built without these development tools.

### Continuous Code Synchronization

The `synch.sh` script provides automated code synchronization with the TPU VM, supporting a CI/CD-like workflow during development:

```bash
# Basic sync of all Python files to the TPU VM
./dev/mgt/synch.sh

# Watch mode: automatically sync when files change
./dev/mgt/synch.sh --watch

# Restart Docker container after syncing
./dev/mgt/synch.sh --restart

# Use Docker Compose watch feature (v2.22.0+)
./dev/mgt/synch.sh --compose-watch

# Sync specific files only
./dev/mgt/synch.sh --specific model.py trainer.py

# Include utils directory in sync
./dev/mgt/synch.sh --utils
```

This enables:
1. Rapid iteration on TPU-specific code
2. Immediate testing without container rebuilds
3. Continuous feedback during development
4. Support for automated testing workflows

### CI/CD Pipeline Integration

The development tools can be integrated into CI/CD pipelines:

1. **Development Phase**:
   - Use `synch.sh --watch` during active development
   - Test changes immediately on the TPU VM

2. **Testing Phase**:
   - Use `mount_run_scrap.sh` to validate changes before committing
   - Automated tests can be run directly on the TPU VM

3. **Deployment Phase**:
   - Build a clean Docker image without development tools
   - Deploy to production TPU environment

For more detailed information on the CI/CD workflow, see the [dev/README.md](dev/README.md) documentation.

## System Requirements

- Docker Desktop installed and running
- Google Cloud SDK installed and configured 
- Python 3.8+ for local development
- Google Cloud account with billing enabled
- Service account with appropriate permissions
- Git for version control

## Acknowledgments

- Google Cloud TPU team for their documentation and support
- PyTorch XLA team for enabling PyTorch on TPUs
- The broader research community for advancing our understanding of Transformer models

## Additional Resources

For more information, refer to:
- [Google Cloud TPU Documentation](https://cloud.google.com/tpu/docs)
- [PyTorch XLA Documentation](https://pytorch.org/xla/)
- [TPU Performance Guide](https://cloud.google.com/tpu/docs/performance-guide)
- [Attention Is All You Need (original Transformer paper)](https://arxiv.org/abs/1706.03762)
- [Transformer architecture studies and analyses](https://arxiv.org/abs/2103.03404)

# TPU Monitoring System Workflow

## Overview

This repository contains a comprehensive system for monitoring TPU (Tensor Processing Unit) workloads. The system provides real-time insights into TPU performance, Google Cloud Storage (GCS) bucket usage, and data transfer metrics. The codebase is designed to be mounted on TPU VMs and run alongside TPU workloads to collect and visualize performance data.

## Directory Structure

The codebase is organized into the following key directories:

- `dev/src/utils/`: Core utilities for monitoring, including:
  - `utils/monitors/`: Classes for monitoring different aspects of TPU execution
  - `utils/dashboards/`: Visualization components for real-time monitoring data
  - `utils/logging/`: Logging utilities for the monitoring system
  - `utils/api/`: API interfaces for external integrations

- `dev/src/`: Contains the main scripts:
  - `example.py`: Example TPU workflow that can be monitored
  - `start_monitoring.py`: Python script to start/stop the monitoring system
  - `start_monitoring.sh`: Shell wrapper for the monitoring system
  - `run_example.sh`: Script to run the example with monitoring enabled

## Workflow

### 1. Starting the Monitoring System

The monitoring system can be started in two ways:

#### Option 1: Direct start using start_monitoring.sh

```bash
# Start with default settings
./dev/src/start_monitoring.sh

# Start with custom configuration
./dev/src/start_monitoring.sh --config path/to/config.yaml --env path/to/.env --webapp
```

#### Option 2: Start with run_example.sh

The `run_example.sh` script starts monitoring automatically before running the example:

```bash
# Run example with monitoring (starts monitoring first)
./dev/src/run_example.sh --bucket my-bucket --matrix-size 5000 --interval 30
```

### 2. Running the TPU Workload (example.py)

The `example.py` script demonstrates a complete TPU workload, including:

1. Creating and uploading mock data to GCS
2. Loading and preprocessing data on TPU
3. Performing matrix multiplication on TPU
4. Storing results back to GCS

The monitoring system collects metrics throughout this execution process.

### 3. Monitoring Features

The monitoring system provides:

- **TPU Performance Metrics**: CPU utilization, memory usage, TPU operations/sec
- **GCS Bucket Monitoring**: Storage usage, read/write operations
- **Data Transfer Tracking**: Network throughput between TPU VM and GCS

Metrics are collected at the specified interval (default: 30 seconds) and can be visualized through:

- TensorBoard dashboards
- Cloud Monitoring (if enabled)
- Real-time API endpoints (if --webapp is enabled)

### 4. Generating Reports

After the workload completes, `run_example.sh` automatically generates a monitoring report:

```bash
# Generate report manually if needed
python dev/src/start_monitoring.py report --output-dir logs/reports
```

### 5. Cleanup

When finished, the monitoring system can be stopped:

```bash
# If --keep-monitoring was not used, run_example.sh stops monitoring automatically
# To stop manually:
python dev/src/start_monitoring.py stop
```

## Configuration

The monitoring system is configured through a standardized system using:

1. A centralized YAML configuration file (`utils/logging/log_config.yaml`)
2. Environment variables from `.env` files with dynamic resolution
3. Command-line arguments to `start_monitoring.py` or `run_example.sh`

The configuration system ensures all components consistently use the same settings for directories, intervals, and credentials.

## Requirements

- Google Cloud Platform account with TPU VMs
- GCS bucket for data storage
- Python 3.7+ with TensorFlow installed
- Google Cloud SDK

## Example Workflow

A typical workflow might look like:

1. Mount code to TPU VM: `./dev/mgt/mount.sh --all`
2. Run example with monitoring: `./dev/src/run_example.sh --bucket my-tpu-data`
3. View generated reports in the `logs/reports` directory
4. Clean up resources: `./dev/mgt/scrap.sh`

## Troubleshooting

If you encounter issues:

- Check the log files in the `logs` directory
- Ensure TPU VM has proper permissions for GCS access
- Verify that all required dependencies are installed
- Check that paths in configuration files match your environment
