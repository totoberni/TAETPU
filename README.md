# Transformer Ablation Experiment on Google Cloud TPU (TAETPU)

This repository contains a framework for conducting Transformer model ablation experiments on Google Cloud TPUs. It provides the infrastructure to set up, run, and analyze experiments that examine the impact of various Transformer architecture components.

## Project Structure

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
│   ├── mgt/                      # Management scripts for development
│   │   ├── mount.sh              # Script to mount files to TPU VM
│   │   ├── run.sh                # Script to execute files on TPU VM
│   │   ├── scrap.sh              # Script to remove files from TPU VM
│   │   └── synch.sh              # Script for syncing and watching code changes
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
│   │       ├── docker-compose.yml # Docker Compose configuration
│   │       ├── entrypoint.sh     # Container entry point script
│   │       └── requirements.txt  # Python dependencies
│   ├── data/                     # Data processing and management
│   │   ├── downloads/            # Local dataset storage
│   │   ├── data_ops.sh           # Unified data operations script
│   │   └── __init__.py           # Package exports
│   ├── teardown/                 # Scripts for resource cleanup
│   │   ├── teardown_bucket.sh    # Script to delete GCS bucket
│   │   ├── teardown_image.sh     # Script to clean up Docker images
│   │   └── teardown_tpu.sh       # Script to delete TPU VM
│   └── utils/                    # Shared utilities
│       ├── common.sh             # Common bash utilities and functions
│       └── data_utils.py         # Data-related utilities
└── source/                       # Configuration and credential files
    ├── .env                      # Environment variables and configuration
    └── service-account.json      # Service account key (not included in repo)
```

## 0. Requirements

Before starting, ensure you have:

- Docker Desktop installed and running
- Google Cloud SDK installed and configured
- Python 3.11+ for local development
- Google Cloud account with billing enabled
- Service account with appropriate permissions
- Git for version control

Make all scripts executable:
```bash
chmod +x src/setup/scripts/*.sh
chmod +x src/teardown/*.sh
chmod +x dev/mgt/*.sh
chmod +x src/data/data_ops.sh
```

## 1. Configuration

Create and configure your environment variables:

```bash
# Copy the template (don't edit the template directly)
cp source/.env.template source/.env

# Edit your .env file with your specific settings
nano source/.env  # or use your preferred editor
```

Your `.env` file should contain:

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
BUCKET_DATRAIN=your-bucket-name/data
BUCKET_TENSORBOARD=your-bucket-name/tensorboard

# Service Account details
SERVICE_ACCOUNT_JSON=your-service-account.json
SERVICE_ACCOUNT_EMAIL=your-service-account@your-project.iam.gserviceaccount.com

# Dataset Configuration
# Format: DATASET_[KEY]_NAME = the dataset name/path on Hugging Face
DATASET_GUTENBERG_NAME="nbeerbower/gutenberg2-dpo"
DATASET_EMOTION_NAME="dair-ai/emotion"
```

> **IMPORTANT:** The `.env` file and service account key files are excluded from version control. Never commit these files to the repository.

## 2. Setup Process

### 2.1 Check for Available TPU Zones

Find a zone where your desired TPU type is available:

```bash
./src/setup/scripts/check_zones.sh
```

This script will:
- Check all zones in your configured TPU_REGION
- Search for availability of your specified TPU_TYPE
- Update your .env file with the correct TPU_ZONE

### 2.2 Set Up Google Cloud Storage Bucket

Create a bucket for storing experiment data, model checkpoints, and logs:

```bash
./src/setup/scripts/setup_bucket.sh
```

### 2.3 Build and Push the Docker Image

Build your Docker image and push it to Google Container Registry:

```bash
./src/setup/scripts/setup_image.sh
```

### 2.4 Set Up TPU VM and Pull Docker Image

Create the TPU VM, pull the Docker image, and start the container:

```bash
./src/setup/scripts/setup_tpu.sh
```

## 3. Development Workflow (CI/CD)

The project implements a streamlined CI/CD workflow for rapid iteration without rebuilding Docker images for every code change.

### 3.1 Directory Structure

The setup process (`setup_tpu.sh`) automatically creates the following directory structure in your project root:

```
mount/
├── src/     # Source code files (mounted to the container)
├── models/  # Model files (persisted between runs)
└── logs/    # Log files (persisted between runs)
```

Source code is mounted to the Docker container, while data files remain on your local machine. This separation keeps the Docker image lightweight and ensures data processing can happen locally.

### 3.2 Data Operations

The project provides a unified data management system for downloading, processing, and managing datasets between your local machine and Google Cloud Storage. The main interface is the `data_ops.sh` script located in `src/data/`.

#### 3.2.1 Data Configuration

Datasets are defined directly in your `.env` file using the following pattern:

```bash
# Dataset Configuration
# Format: DATASET_[KEY]_NAME = the dataset name/path on Hugging Face
DATASET_GUTENBERG_NAME="nbeerbower/gutenberg2-dpo"
DATASET_EMOTION_NAME="dair-ai/emotion"
```

To add a new dataset, simply add a new environment variable following this naming convention.

#### 3.2.2 Unified Data Operations Command

The `data_ops.sh` script provides a single command interface for all data operations:

```bash
# Show help and available commands
./src/data/data_ops.sh --help

# Download datasets from Hugging Face to local storage
./src/data/data_ops.sh download-local

# Upload datasets to Google Cloud Storage bucket
./src/data/data_ops.sh upload --bucket-name your-bucket-name

# Download datasets from GCS bucket to local storage
./src/data/data_ops.sh download-gcs --bucket-name your-bucket-name

# List all files/datasets in the GCS bucket
./src/data/data_ops.sh list --bucket-name your-bucket-name

# Count files in GCS bucket datasets
./src/data/data_ops.sh count --bucket-name your-bucket-name

# Remove datasets from GCS bucket
./src/data/data_ops.sh clean --bucket-name your-bucket-name --datasets dataset1 dataset2
```

All commands support the following options:
- `--output-dir DIR`: Specify output directory (defaults to `src/data/downloads`)
- `--bucket-name NAME`: Specify GCS bucket name (from environment by default)
- `--datasets LIST`: Specify dataset names to process

The script automatically:
- Reads dataset configurations from your environment variables
- Sets up authentication for Google Cloud Storage operations
- Uses the appropriate paths for GCS operations (from BUCKET_DATRAIN in .env)
- Provides appropriate error handling and status reporting

#### 3.2.3 How It Works

The integrated `data_ops.sh` script:

1. **Downloads datasets** directly using Python's datasets library, using dataset names from environment variables
2. **Uploads/downloads** data to/from Google Cloud Storage using the `gcloud storage cp` command with proper recursive handling
3. **Lists** all content in the specified bucket with detailed information
4. **Counts** files in bucket datasets to help track dataset size and verify transfers
5. **Cleans** datasets from GCS buckets (with confirmation safeguards)

All operations maintain consistent error handling, logging, and output directory management.

### 3.3 Mounting Files to TPU VM

The `mount.sh` script copies Python files from your local development environment to the TPU VM:

```bash
# Mount a specific file to the TPU VM
./dev/mgt/mount.sh example.py

# Mount multiple files
./dev/mgt/mount.sh file1.py file2.py

# Mount all files in dev/src directory
./dev/mgt/mount.sh --all

# Mount specific directories
./dev/mgt/mount.sh --dir exp/data
```

Files are mounted into the `/app/mount/src` directory on the TPU VM, which is directly mapped to the Docker container. The container creates symbolic links to provide easy access to these directories.

### 3.4 Running Files on TPU VM

The `run.sh` script executes mounted Python files inside the Docker container:

```bash
# Run a mounted file on the TPU VM
./dev/mgt/run.sh example_monitoring.py

# Run a file in a subdirectory
./dev/mgt/run.sh exp/data/buckets/load_bucket.py

# Run with arguments
./dev/mgt/run.sh train.py --epochs 10 --batch_size 32
```

### 3.5 Continuous Synchronization

The `synch.sh` script provides automated file synchronization with the TPU VM:

```bash
# Basic sync of files to TPU VM
./dev/mgt/synch.sh

# Watch mode: automatically sync when files change
./dev/mgt/synch.sh --watch

# Restart container after syncing
./dev/mgt/synch.sh --restart
```

### 3.6 Removing Files from TPU VM

The `scrap.sh` script cleans up files from the TPU VM:

```bash
# Remove specific files (will prompt for confirmation)
./dev/mgt/scrap.sh file1.py file2.py

# Remove all files (will prompt for confirmation)
./dev/mgt/scrap.sh --all

# Prune Docker volumes (will prompt for confirmation)
./dev/mgt/scrap.sh --prune
```

## 4. Docker Container Architecture

The project's Docker container enables:

- **TPU Access**: Maps TPU devices and sets required environment variables
- **Monitoring**: Automatic TensorBoard startup (port 6006)
- **API Server**: Flask API for experiment management (port 5000)
- **Persistent Storage**: Volume mounts for code deployment and data storage

## 5. Example Monitoring Usage

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
    use_wandb=False
)

# Profile model performance
profiler = ModelProfiler(model, log_dir="logs/profiler")
profiler.profile_memory("Before training")

# Log TPU metrics during training
tpu_logger = TPUMetricsLogger()
tpu_logger.log_metrics(step=current_step)
```

## 6. Teardown Resources

When you're done with your TPU resources, clean up in this order:

```bash
# Delete the TPU VM
./src/teardown/teardown_tpu.sh

# Delete the Docker images (local and GCR)
./src/teardown/teardown_image.sh

# Delete the GCS bucket (will prompt for confirmation)
./src/teardown/teardown_bucket.sh
```

## 7. Additional Resources

- [Google Cloud TPU Documentation](https://cloud.google.com/tpu/docs)
- [PyTorch XLA Documentation](https://pytorch.org/xla/)
- [TPU Performance Guide](https://cloud.google.com/tpu/docs/performance-guide)