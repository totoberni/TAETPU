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

The project has been fully refactored to ensure that all scripts can be called from any directory, with proper path resolution and consistent logging.

```
.
├── .gitattributes                # Git attributes configuration
├── .gitignore                    # Git ignore configuration
├── README.md                     # Project documentation (this file)
├── dev/                          # Development environment for rapid iteration
│   ├── src/                      # Development code to run on TPU
│   │   ├── example.py            # Example file for TPU code development
│   │   ├── example_monitoring.py # Example using monitoring capabilities 
│   │   └── utils/                # Utilities for development code
│   │       ├── experiment.py     # Experiment tracking utilities
│   │       ├── profiling.py      # TPU profiling utilities
│   │       ├── tpu_logging.py    # TPU-specific logging utilities
│   │       └── visualization.py  # Data visualization utilities
│   ├── mgt/                      # Management scripts for development (all self-contained)
│   │   ├── mount.sh              # Script to mount files to TPU VM
│   │   ├── run.sh                # Script to execute files on TPU VM
│   │   ├── scrap.sh              # Script to remove files from TPU VM
│   │   ├── mount_run_scrap.sh    # All-in-one script to mount, run, and clean up
│   │   ├── synch.sh              # Enhanced script for syncing and watching code changes (CI/CD)
│   │   └── monitor_tpu.sh        # Self-contained TPU monitoring script
│   └── README.md                 # Documentation for the development workflow
├── setup/                        # Setup and execution scripts
│   ├── scripts/                  # Setup, teardown and utility scripts
│   │   ├── check_zones.sh        # Script to find available TPU zones
│   │   ├── common.sh             # Common bash utilities and logging functions
│   │   ├── setup_bucket.sh       # Script to create GCS bucket
│   │   ├── setup_image.sh        # Script to build and push Docker image to GCR
│   │   ├── setup_tpu.sh          # Script to create TPU VM and pull Docker image
│   │   ├── teardown_bucket.sh    # Script to delete GCS bucket
│   │   ├── teardown_image.sh     # Script to clean up Docker images locally and in GCR
│   │   ├── teardown_tpu.sh       # Script to delete TPU VM
│   │   ├── verify_setup.sh       # Script to verify TPU setup and PyTorch/XLA
│   │   └── verify.py             # Python verification utility for TPU setup
│   └── docker/                   # Docker configuration
│       ├── Dockerfile            # Docker image definition
│       └── requirements.txt      # Python dependencies
└── source/                       # Configuration and credential files
    ├── .env                      # Environment variables and configuration
    └── service-account.json      # Service account key (replace with your own)
```

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
chmod +x setup/scripts/*.sh
chmod +x dev/mgt/*.sh
```

#### 2. Check for Available TPU Zones

First, find a zone where your desired TPU type is available:

```bash
# Run the zone checker (can be run from any directory)
./setup/scripts/check_zones.sh
```

This script will:
- Check all zones in your configured TPU_REGION
- Search for availability of your specified TPU_TYPE
- Automatically update your .env file with the correct TPU_ZONE

#### 3. Set Up Google Cloud Storage Bucket

Create a bucket for storing experiment data, model checkpoints, and logs:

```bash
./setup/scripts/setup_bucket.sh
```

#### 4. Build and Push the Docker Image

Build your Docker image and push it to Google Container Registry:

```bash
./setup/scripts/setup_image.sh
```

#### 5. Set Up TPU VM and Pull Docker Image

Create the TPU VM and pull the Docker image:

```bash
./setup/scripts/setup_tpu.sh
```

#### 6. Verify TPU Environment

Verify that PyTorch and XLA are properly installed and can access the TPU:

```bash
./setup/scripts/verify_setup.sh
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
./setup/scripts/teardown_tpu.sh

# Delete the Docker images (local and GCR)
./setup/scripts/teardown_image.sh

# Delete the GCS bucket (will prompt for confirmation)
./setup/scripts/teardown_bucket.sh
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

## Recent Improvements

The codebase has been refactored with the following improvements:

1. **Absolute Path References**: All scripts now use absolute path resolution to determine their location, allowing them to be called from any directory in the project.

2. **Centralized Logging**: Most scripts utilize a common logging framework from `common.sh` for consistent output styling and error handling.

3. **Environment Variable Validation**: Scripts now properly validate required environment variables before execution.

4. **Enhanced Error Handling**: Better error reporting and graceful failures when prerequisites aren't met.

5. **Self-Contained Development Scripts**: The scripts in `dev/mgt` are now self-contained with their own logging functions, avoiding cross-directory dependencies.

6. **Improved Security**: Scripts properly check for and use service account credentials when available.

7. **Consistent Configuration**: All scripts use the same approach to loading and validating configuration.

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
