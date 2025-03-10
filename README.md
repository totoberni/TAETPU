# Transformer Ablation Experiment on Google Cloud TPU (TAETPU)

This repository contains a comprehensive framework for conducting Transformer model ablation experiments on Google Cloud TPUs. It provides the necessary infrastructure to set up, run, and analyze experiments that examine the impact of various Transformer architecture components on model performance.

## 0. Project Premise and Structure

### Project Purpose

The goal of this project is to systematically study how different components of Transformer architectures affect performance, efficiency, and behavior. Through ablation studies, we can gain insights into:

1. The relative importance of various Transformer mechanisms (attention heads, feed-forward networks, layer normalization, etc.)
2. How architectural choices impact performance on different tasks
3. Potential optimizations for specific use cases and hardware (particularly TPUs)
4. The minimum viable architecture needed for specific performance thresholds

### What Are Ablation Studies?

Ablation studies involve systematically removing, replacing, or modifying components of a model to understand their contribution to the overall performance. In the context of Transformers, we might:

- Remove individual attention heads
- Vary the number of layers
- Modify the feed-forward network size
- Replace layer normalization with alternatives
- Adjust positional encoding schemes

### Why TPUs?

Transformer models are computationally intensive to train and evaluate. Google Cloud TPUs provide:

1. Specialized hardware designed for the matrix operations common in Transformers
2. Significant acceleration compared to CPU/GPU for certain workloads
3. Scalability for large models and datasets
4. Cost efficiencies for long-running experiments

### Project Structure

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
│   │   └── synch.sh              # Enhanced script for syncing and watching code changes (CI/CD)
├── src/                          # Source code for the project
│   ├── setup/                    # Setup scripts and configuration
│   │   ├── scripts/              # Scripts for setting up the environment
│   │   │   ├── check_zones.sh    # Script to find available TPU zones
│   │   │   ├── setup_bucket.sh   # Script to create GCS bucket
│   │   │   ├── setup_image.sh    # Script to build and push Docker image to GCR
│   │   │   ├── setup_tpu.sh      # Script to create TPU VM and pull Docker image
│   │   │   └── verify_setup.sh   # Script to verify TPU setup and PyTorch/XLA
│   │   └── docker/               # Docker configuration
│   │       ├── Dockerfile        # Docker image definition
│   │       ├── entrypoint.sh     # Container entry point script
│   │       ├── tpu.env           # TPU-specific environment variables
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

## 1. Setting Up the Environment

Before running transformer ablation experiments, you need to set up the Google Cloud TPU environment. The following instructions walk you through this process.

### Configuration

Create and configure your environment variables:

```bash
# Copy the template (don't edit the template directly)
cp source/.env.template source/.env

# Edit your .env file with your specific settings
nano source/.env  # or use your preferred editor
```

Your `.env` file should contain the following settings:

```bash
# Project Configuration
PROJECT_ID=your-project-id
TPU_REGION=europe-west4
TPU_ZONE=europe-west4-a
BUCKET_REGION=europe-west4
TPU_NAME=your-tpu-name
TPU_TYPE=v2-8
RUNTIME_VERSION=tpu-ubuntu2204-base

# Cloud Storage
BUCKET_NAME=your-bucket-name

# Service Account details
SERVICE_ACCOUNT_JSON=your-service-account.json
SERVICE_ACCOUNT_EMAIL=your-service-account@your-project.iam.gserviceaccount.com
```

> **IMPORTANT SECURITY NOTE:** The `.env` file and service account key files are automatically excluded from version control by `.gitignore`. Never commit these files to the repository as they contain sensitive information.

### Complete Workflow for TPU Setup

Follow these steps in order to set up your TPU environment:

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
x
```

This script:
- Creates a temporary build context with required files
- Copies utility modules and Docker configuration
- Builds the Docker image locally
- Tags and pushes it to Google Container Registry

#### 5. Set Up TPU VM and Pull Docker Image

Create the TPU VM and pull the Docker image:

```bash
./src/setup/scripts/setup_tpu.sh
```

This script:
- Verifies the TPU VM doesn't already exist
- Creates the TPU VM with appropriate parameters
- Configures Docker authentication on the TPU VM
- Pulls the Docker image from Google Container Registry

## 2. Development Workflow (CI/CD)

The project implements a streamlined CI/CD workflow for rapid iteration without rebuilding Docker images for every code change.

### Development vs. Production

**Important Note**: The `dev/` folder and its contents are designed for development only and **will not be included in the production deployment**. During development, code can be quickly synced and tested; for production, a clean Docker image is built without these development tools.

### Mounting Files to TPU VM

The `mount.sh` script copies Python files from your local development environment to the TPU VM, making them available for execution:

```bash
# Mount a specific file to the TPU VM (can be run from any directory)
./dev/mgt/mount.sh example.py

# Mount multiple files
./dev/mgt/mount.sh file1.py file2.py

# Mount all files in dev/src directory
./dev/mgt/mount.sh --all
```

The mounted files are stored in `/tmp/app/mount` on the TPU VM, which is then mounted to `/app/mount` inside the Docker container.

### Running Files on TPU VM

The `run.sh` script executes mounted Python files inside a Docker container on the TPU VM:

```bash
# Run a mounted file on the TPU VM
./dev/mgt/run.sh example_monitoring.py

# Run with arguments
./dev/mgt/run.sh train.py --epochs 10 --batch_size 32
```

The script:
- Configures Docker authentication on the TPU VM
- Verifies the file exists in the mounted directory
- Runs the file in a Docker container with TPU access
- Automatically falls back to sudo if needed

### Removing Files from TPU VM

The `scrap.sh` script cleans up files from the TPU VM:

```bash
# Remove specific files
./dev/mgt/scrap.sh file1.py file2.py

# Remove all files
./dev/mgt/scrap.sh --all

# Prune Docker volumes
./dev/mgt/scrap.sh --prune
```

### Continuous Synchronization

The `synch.sh` script provides automated file synchronization with the TPU VM:

```bash
# Basic sync of files to TPU VM
./dev/mgt/synch.sh

# Watch mode: automatically sync when files change
./dev/mgt/synch.sh --watch

# Restart container after syncing
./dev/mgt/synch.sh --restart
```

This enables:
- Rapid iteration on TPU-specific code
- Immediate testing without container rebuilds
- Continuous feedback during development

## 3. Web Application Infrastructure

The Docker container includes a built-in web application infrastructure for monitoring and visualization:

### Exposed Services

- **Flask API Server**: Port 5000
  - Provides REST API for experiment management
  - Offers TPU monitoring endpoints
  - Runs in the container by default

- **TensorBoard**: Port 6006
  - Visualization of training metrics
  - Model graph exploration
  - Profile TPU performance

### Container Architecture

The Docker container is designed with:

1. **Proper TPU Access**:
   - Maps TPU devices into the container
   - Sets required environment variables
   - Configures library paths for TPU access

2. **Monitoring Backend**:
   - Custom entrypoint script for service management
   - Automatic logging and metric collection
   - REST API for external monitoring

3. **Persistent Storage**:
   - Volume mounts for code deployment
   - Configurable data storage location
   - Log persistence across container restarts

### Running the Web Services

The services are automatically started when the container runs:

```bash
# Run the container with web services enabled
docker run --privileged --rm \
  -v /dev:/dev \
  -v /lib/libtpu.so:/lib/libtpu.so \
  -p 5000:5000 \
  -p 6006:6006 \
  gcr.io/${PROJECT_ID}/tae-tpu:v1
```

## 4. Teardown Resources

When you're done with your TPU resources, clean up in this order:

```bash
# Delete the TPU VM
./src/teardown/teardown_tpu.sh

# Delete the Docker images (local and GCR)
./src/teardown/teardown_image.sh

# Delete the GCS bucket (will prompt for confirmation)
./src/teardown/teardown_bucket.sh
```

## 5. Further Instructions

### Enhanced Monitoring & Logging

This framework includes comprehensive monitoring and logging capabilities specifically designed for TPU-based experiments:

#### Key Features

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

#### Example Monitoring Usage

```python
# Import utilities
from utils.tpu_logging import setup_logger, TPUMetricsLogger
from utils.profiling import ModelProfiler, profile_function
from utils.experiment import ExperimentTracker

# Set up logger with file output
logger = setup_logger(log_level="INFO", log_file="logs/experiment.log")

# Track experiment metrics
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

### System Requirements

- Docker Desktop installed and running
- Google Cloud SDK installed and configured 
- Python 3.11+ for local development
- Google Cloud account with billing enabled
- Service account with appropriate permissions
- Git for version control

### Additional Resources

For more information, refer to:
- [Google Cloud TPU Documentation](https://cloud.google.com/tpu/docs)
- [PyTorch XLA Documentation](https://pytorch.org/xla/)
- [TPU Performance Guide](https://cloud.google.com/tpu/docs/performance-guide)
- [Attention Is All You Need (original Transformer paper)](https://arxiv.org/abs/1706.03762)
- [Transformer architecture studies and analyses](https://arxiv.org/abs/2103.03404)
