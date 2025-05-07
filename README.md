# Transformer Ablation Experiment on Google Cloud TPU (TAETPU)

This repository contains a robust framework for conducting Transformer model ablation experiments on Google Cloud TPUs. It provides complete infrastructure for setting up, running, and analyzing experiments that examine the impact of various Transformer architecture components.

## Table of Contents

- [Project Overview](#project-overview)
- [Project Structure](#project-structure)
- [Requirements](#requirements)
- [Setup Process](#setup-process)
  - [Configuration](#configuration)
  - [Check for Available TPU Zones](#check-for-available-tpu-zones)
  - [Build and Push the Docker Image](#build-and-push-the-docker-image)
  - [Set Up TPU VM and Pull Docker Image](#set-up-tpu-vm-and-pull-docker-image)
- [Development Workflow](#development-workflow)
  - [Working with Docker Container](#working-with-docker-container)
  - [Validating the Docker Environment](#validating-the-docker-environment)
  - [Working with Data](#working-with-data)
  - [Viewing Datasets](#viewing-datasets)
- [Volume Management](#volume-management)
- [Teardown Resources](#teardown-resources)
- [Troubleshooting Guide](#troubleshooting-guide)
- [Additional Resources](#additional-resources)

## Project Overview

TAETPU is designed to facilitate research into the importance of different Transformer architecture components by providing a standardized environment for experiments. The framework handles:

- Infrastructure setup (TPU provisioning, Docker image management)
- Data preprocessing (tokenization, alignment, transformer-specific processing)
- File synchronization between local environment and TPU VMs
- Dataset management and visualization
- Resource cleanup

The project uses Docker containers to ensure consistent environments and Google Cloud TPUs for accelerated training.

## Project Structure

```
.
├── .gitattributes                # Git attributes configuration
├── .gitignore                    # Git ignore configuration
├── README.md                     # Project documentation
├── config/                       # Configuration and credential files
│   └── infra-tempo-####          # Service account key
├── infrastructure/               # Infrastructure setup and management
│   ├── setup/                    # Scripts for setting up the environment
│   │   ├── check_zones.sh        # Script to find available TPU zones
│   │   ├── setup_image.sh        # Script to build and push Docker image to GCR
│   │   └── setup_tpu.sh          # Script to create TPU VM and pull Docker image
│   ├── docker/                   # Docker configuration
│   │   ├── Dockerfile            # Docker image definition
│   │   ├── docker-compose.yml    # Docker Compose configuration
│   │   ├── entrypoint.sh         # Container entry point script
│   │   └── requirements.txt      # Python dependencies for Docker
│   ├── mgt/                      # Management scripts for Docker operations
│   │   ├── mount.sh              # Script to mount files to Docker container
│   │   ├── run.sh                # Script to execute files in Docker container
│   │   ├── sync.sh               # Script to synchronize files between local and container
│   │   └── scrap.sh              # Script to remove files from Docker container
│   ├── utils/                    # Shared utilities
│   │   ├── logging/              # Logging utilities
│   │   └── monitors/             # Monitoring utilities
│   └── teardown/                 # Scripts for resource cleanup
│       ├── teardown_image.sh     # Script to clean up Docker images
│       └── teardown_tpu.sh       # Script to delete TPU VM
└── src/                          # Source code for TPU experiments
    ├── configs/                  # Configuration files for experiments
    ├── data/                     # Data processing package
    │   ├── processors/           # Data processors
    │   ├── tasks/                # Task generators
    │   └── utils/                # Utility functions
    ├── datasets/                 # Dataset files
    │   ├── clean/                # Processed datasets
    │   │   ├── static/           # Static embedding datasets
    │   │   └── transformer/      # Transformer model datasets
    │   └── raw/                  # Raw downloaded datasets
    ├── models/                   # Model definitions and components
    │   └── prep/                 # Preprocessing models
    ├── cache/                    # Cached preprocessing results
    │   └── prep/                 # Preprocessing cache
    └── example.py                # Example script
```

## Requirements

Before starting, ensure you have:

- Docker Desktop installed and running
- Google Cloud SDK installed and configured
- Python 3.11+ for local development
- Google Cloud account with billing enabled
- Service account with appropriate permissions
- Git for version control

Make all scripts executable:
```bash
chmod +x infrastructure/setup/*.sh
chmod +x infrastructure/teardown/*.sh
chmod +x infrastructure/utils/*.sh
chmod +x infrastructure/mgt/*.sh
```

## Setup Process

### Configuration

Your service account requires the following permissions:
- `roles/tpu.admin` - For creating and managing TPUs
- `roles/storage.admin` - For accessing GCS and Artifact Registry
- `roles/compute.admin` - For VM operations

Create and configure your environment variables:

```bash
# Create your .env file with your specific settings
nano config/.env  # or use your preferred editor
```

Your `.env` file should contain:

```bash
# Project Configuration
PROJECT_ID=your-project-id              # Your Google Cloud project ID
TPU_REGION=europe-west4                 # Region for TPU deployment
TPU_ZONE=europe-west4-a                 # Zone within the region for TPU
TPU_NAME=your-tpu-name                  # Name for your TPU instance
TPU_TYPE=v2-8                           # TPU type (v2-8, v3-8, etc.)
RUNTIME_VERSION=tpu-ubuntu2204-base     # TPU VM runtime version

# Container Configuration 
CONTAINER_NAME=tae-tpu-container        # Docker container name (IMPORTANT: must match in all scripts)
CONTAINER_TAG=latest                    # Container tag to use
IMAGE_NAME=eu.gcr.io/${PROJECT_ID}/tae-tpu:v1  # Docker image name with registry

# Service Account details
SERVICE_ACCOUNT_JSON=your-service-account.json  # JSON key filename
SERVICE_ACCOUNT_EMAIL=your-service-account@your-project.iam.gserviceaccount.com  # Service account email

# Dataset Configuration
# Format: DATASET_[KEY]_NAME = the dataset name/path on Hugging Face
DATASET_GUTENBERG_NAME="nbeerbower/gutenberg2-dpo"
DATASET_EMOTION_NAME="dair-ai/emotion"

# Volume Management Options (optional)
HOST_SRC_DIR=/tmp/tae_src                 # Local host directory for src
USE_NAMED_VOLUMES=false                   # Whether to use Docker named volumes
VOLUME_PREFIX=tae                         # Prefix for Docker named volumes
```

### Check for Available TPU Zones

Find a zone where your desired TPU type is available:

```bash
./infrastructure/setup/check_zones.sh
```

This script:
1. Authenticates with GCP using your service account
2. Lists available zones in your configured region
3. Checks each zone for your specified TPU type
4. Updates your `.env` file with the first available zone

### Build and Push the Docker Image

Build your Docker image and push it to Google Container Registry:

```bash
./infrastructure/setup/setup_image.sh
```

This script:
1. Authenticates with Google Container Registry
2. Cleans up any existing containers/images with same name
3. Builds the Docker image using docker-compose
4. Pushes the image to GCR

### Set Up TPU VM and Pull Docker Image

Create the TPU VM, pull the Docker image, and start the container:

```bash
./infrastructure/setup/setup_tpu.sh
```

This script:
1. Creates a TPU VM with your specified configuration
2. Configures authentication for Docker on the VM
3. Pulls your Docker image from GCR
4. Creates necessary Docker volumes for persistent storage
5. Runs the container with TPU access and mounted volumes

## Development Workflow

### Working with Docker Container

The project provides four management scripts for working with the Docker container:

#### 1. File Management Overview

| Script | Purpose | Key Features |
|--------|---------|-------------|
| `mount.sh` | Copies files to container | Directory structure preservation, full/partial mounting |
| `run.sh` | Executes scripts or commands | Python script execution, shell command execution, directory navigation |
| `sync.sh` | Keeps files in sync | Two-way synchronization, dry run mode, selective updates |
| `scrap.sh` | Removes files from container | Selective/complete cleanup, directory preservation |

These scripts maintain directory structure isometry between your local machine and the Docker container.

#### 2. Mounting Files (`mount.sh`)

Use `mount.sh` to copy files from your local environment to the Docker container:

```bash
# Mount all files in the src directory
./infrastructure/mgt/mount.sh --all

# Mount a specific file
./infrastructure/mgt/mount.sh example.py

# Mount a specific directory
./infrastructure/mgt/mount.sh --dir data
```

`mount.sh` options:
- `--all`: Mount the entire src directory structure
- `--dir [directory]`: Mount a specific directory and its contents
- `--named-volumes`: Use Docker named volumes instead of host directories
- `--type [volume-type]`: Specify volume type (src, datasets, models, etc.)

#### 3. Running Code (`run.sh`)

The `run.sh` script allows you to run Python scripts or shell commands in the container:

```bash
# Run a Python script
./infrastructure/mgt/run.sh example.py --arg value

# Execute a shell command in the default directory (/app/mount)
./infrastructure/mgt/run.sh --command "ls -la"

# Execute a command in a specific directory
./infrastructure/mgt/run.sh --command "cat data_config.yaml" src/configs

# Start an interactive shell in a specific directory
./infrastructure/mgt/run.sh --interactive --command "bash" src
```

`run.sh` options:
- Regular mode: `run.sh [script_path] [arguments]` - Executes a Python script
- Command mode: `run.sh --command "[command]" [directory]` - Executes a shell command
  - Optional directory parameter to specify working directory (relative to /app/mount)
- `--interactive`, `-i`: Run command in interactive mode (with TTY)
- `--help`, `-h`: Show help message

#### 4. Synchronizing Files (`sync.sh`)

Use `sync.sh` to efficiently update files that have changed:

```bash
# Sync all files in the src directory
./infrastructure/mgt/sync.sh --all

# Sync a specific file
./infrastructure/mgt/sync.sh example.py

# Sync a specific directory
./infrastructure/mgt/sync.sh data

# Preview sync changes without applying them
./infrastructure/mgt/sync.sh --all --dry-run

# Show detailed information during sync
./infrastructure/mgt/sync.sh --all --verbose
```

`sync.sh` options:
- `--all`: Sync all files in the src directory
- `--dry-run`: Show what would be updated without making changes
- `--verbose`: Show detailed information about file comparison

#### 5. Cleaning Up Files (`scrap.sh`)

Use `scrap.sh` to remove files from the Docker container:

```bash
# Remove all files from /app/mount (completely clean)
./infrastructure/mgt/scrap.sh --all

# Remove a specific directory
./infrastructure/mgt/scrap.sh --dir cache

# Remove specific files
./infrastructure/mgt/scrap.sh data/example.py models/test_model.py
```

`scrap.sh` options:
- `--all`: Remove all files from the container mount directory
- `--dir [directory]`: Remove a specific directory and its contents
- File arguments: Remove specific files

#### 6. Typical Workflow Patterns

Here are typical file management patterns you might use:

**Initial Setup:**
```bash
# Mount entire src directory
./infrastructure/mgt/mount.sh --all

# Run validation script
./infrastructure/mgt/run.sh data/validate_docker.py
```

**Development Cycle:**
```bash
# Edit files locally, then sync changes
./infrastructure/mgt/sync.sh --all

# Run your script with the changes
./infrastructure/mgt/run.sh data/pipeline.py --model transformer

# Check results with shell commands
./infrastructure/mgt/run.sh --command "ls -la" src/datasets/clean

# View logs or outputs
./infrastructure/mgt/run.sh --command "cat output.log" src
```

**Cleanup:**
```bash
# Remove temporary files, keep important data
./infrastructure/mgt/scrap.sh --dir cache/prep

# Complete cleanup
./infrastructure/mgt/scrap.sh --all
```

### Validating the Docker Environment

Before running experiments, you can validate that the Docker environment is properly set up:

```bash
# Mount the validation script
./infrastructure/mgt/mount.sh data/validate_docker.py

# Run the validation script
./infrastructure/mgt/run.sh data/validate_docker.py
```

The validation script checks:
- Access to all required directories
- Import of required Python modules
- Basic data operations with PyTorch and NumPy
- File I/O operations in mounted directories
- Proper functioning of the data types module
- TPU availability (if running on TPU hardware)

### Working with Data

The data processing pipeline supports the following operations:

```bash
# Download and preprocess datasets
./infrastructure/mgt/run.sh data/pipeline.py --download

# Run full preprocessing pipeline
./infrastructure/mgt/run.sh data/pipeline.py --model all --dataset all

# Run transformer preprocessing only
./infrastructure/mgt/run.sh data/pipeline.py --model transformer --dataset all

# Run static embedding preprocessing only
./infrastructure/mgt/run.sh data/pipeline.py --model static --dataset all
```

#### Data Processing Pipeline Options

The data pipeline supports the following options:

- **Model and Dataset Selection**:
  - `--model [transformer|static|all]`: Select model type to process for
  - `--dataset [gutenberg|emotion|all]`: Select dataset to process

- **Pipeline Control**:
  - `--download`: Download and prepare raw datasets
  - `--preprocess`: Preprocess datasets (default if no mode specified)
  - `--view`: View datasets instead of processing them
  - `--force`: Force overwrite existing processed data
  - `--disable-cache`: Disable caching of preprocessed data
  - `--n-processes N`: Number of parallel processes to use

- **Resource Configuration**:
  - `--config PATH`: Path to data configuration YAML file
  - `--output-dir DIR`: Directory for processed outputs
  - `--cache-dir DIR`: Directory for caching intermediate results
  - `--raw-dir DIR`: Directory with raw datasets

- **Performance Options**:
  - `--optimize-for-tpu`: Optimize preprocessing for TPU compatibility
  - `--profile`: Enable performance profiling

- **Dataset Viewing**:
  - `--dataset-type [raw|clean|auto]`: Type of datasets to view
  - `--examples N`: Number of examples to show (default: 3)
  - `--detailed`: Show detailed information about examples

### Viewing Datasets

You can view the raw or processed datasets:

```bash
# View raw datasets
./infrastructure/mgt/run.sh data/pipeline.py --view --dataset-type raw

# View processed datasets
./infrastructure/mgt/run.sh data/pipeline.py --view --dataset-type clean

# View only transformer datasets with detailed information
./infrastructure/mgt/run.sh data/pipeline.py --view --model transformer --detailed

# View a specific dataset
./infrastructure/mgt/run.sh data/pipeline.py --view --dataset gutenberg
```

## Volume Management

The project implements best practices for Docker volume management to ensure consistent operation.

### Container Naming and Consistency

All scripts use a consistent approach to container and image naming:
- Use `CONTAINER_NAME` from environment variables (defaults to `tae-tpu-container`)
- Use `CONTAINER_TAG` from environment variables (defaults to `latest`)
- Use `IMAGE_NAME` from environment variables (defaults to `eu.gcr.io/${PROJECT_ID}/tae-tpu:v1`)

### Volume Management Options

The system supports two approaches to volume management:

1. **Host Directory Mounting (Default)**:
   ```bash
   # Mount files using host directories
   ./infrastructure/mgt/mount.sh --all
   ./infrastructure/mgt/mount.sh --dir data
   ```

2. **Named Volume Mounting**:
   ```bash
   # Mount files using Docker named volumes
   ./infrastructure/mgt/mount.sh --named-volumes --all
   ./infrastructure/mgt/mount.sh --named-volumes --dir data
   ```

All management scripts implement automatic recovery mechanisms:
- Detect container name mismatches and resolve them
- Create aliases automatically when mismatches detected
- Provide detailed error messages with explicit resolution steps

## Teardown Resources

When you're done with your TPU resources:

```bash
# Delete the TPU VM
./infrastructure/teardown/teardown_tpu.sh

# Delete the Docker images (local and GCR)
./infrastructure/teardown/teardown_image.sh
```

The teardown scripts provide:
- Interactive confirmation to prevent accidental deletions
- Complete resource cleanup to avoid ongoing charges
- Proper GCP service disconnection
- Local Docker image cleanup

## Troubleshooting Guide

### Container Name Mismatch

If you encounter "Unable to find image 'tae-tpu-container:latest' locally" error:

```bash
# Quick fix: Tag the existing image with the name expected by the scripts
docker tag eu.gcr.io/${PROJECT_ID}/tae-tpu:v1 tae-tpu-container:latest

# Verify container exists
docker ps -a | grep tae-tpu
```

### Docker Volume Issues

If container can't access mounted volumes:

```bash
# Check volume permissions
docker exec tae-tpu-container ls -la /app/mount

# Fix permissions if needed
docker exec tae-tpu-container chmod -R 777 /app/mount
```

### TPU Connectivity Problems

If scripts can't connect to TPU:

```bash
# Verify TPU exists and is running
gcloud compute tpus tpu-vm list --zone=$TPU_ZONE

# Check TPU status
gcloud compute tpus tpu-vm describe $TPU_NAME --zone=$TPU_ZONE
```

## Task Generation and TPU Optimization

The framework includes comprehensive task generation capabilities and TPU-specific optimizations:

### Task Generators

Eight pre-implemented task generators are available for different NLP tasks:

| Task Type | Description | Use Case |
|-----------|-------------|----------|
| MLM | Masked Language Modeling | Standard BERT-style pretraining |
| LMLM | Large span Masked Language Modeling | Long-range dependency learning |
| NER | Named Entity Recognition | Entity extraction with BIO tagging |
| POS | Part-of-Speech tagging | Syntactic analysis |
| NSP | Next Sentence Prediction | Document coherence modeling |
| Discourse | Discourse marker prediction | Rhetorical structure analysis |
| Sentiment | Sentiment/emotion classification | Affective computing |
| Contrastive | Contrastive learning | Similarity encoding with validation |

### TPU-Specific Optimizations

The preprocessing pipeline incorporates several TPU-specific optimizations:

- Padding to multiples of 8 for all tensor dimensions (critical for XLA)
- Fixed batch sizes that are multiples of 8 (preferably 128 per TPU core)
- Static shapes across all datasets to prevent XLA recompilations
- Memory-efficient implementations for maximum throughput
- Standardized array format outputs for direct TPU consumption
- BFloat16 precision for optimal numerical stability
- Length-based bucketing for efficient processing

## Additional Resources

- [Google Cloud TPU Documentation](https://cloud.google.com/tpu/docs)
- [PyTorch XLA Documentation](https://pytorch.org/xla/)
- [TPU Performance Guide](https://cloud.google.com/tpu/docs/performance-guide)
- [Docker with TPU Guide](https://cloud.google.com/tpu/docs/run-in-container)