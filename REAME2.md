# Transformer Ablation Experiment on Google Cloud TPU (TAETPU)

This repository contains a framework for conducting Transformer model ablation experiments on Google Cloud TPUs. It provides the infrastructure to set up, run, and analyze experiments that examine the impact of various Transformer architecture components.

## Project Structure

```
.
├── .gitattributes                # Git attributes configuration
├── .gitignore                    # Git ignore configuration
├── README.md                     # Project documentation (this file)
├── config/                       # Configuration and credential files
│   ├── .env                      # Environment variables and configuration
│   ├── requirements.txt          # Python dependencies for the project
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
│   │   └── scrap.sh              # Script to remove files from Docker container
│   ├── utils/                    # Shared utilities
│   │   ├── common.sh             # Common bash utilities and functions
│   │   ├── monitors/             # Monitoring utilities
│   │   └── logging/              # Logging utilities
│   └── teardown/                 # Scripts for resource cleanup
│       ├── teardown_image.sh     # Script to clean up Docker images
│       └── teardown_tpu.sh       # Script to delete TPU VM
└── src/                          # Source code for TPU experiments
    ├── configs/                  # Configuration files for experiments
    │   └── data_config.yaml      # Configuration for data preprocessing
    ├── data/                     # Data processing and management
    │   ├── data_import.py        # Script to download and process datasets
    │   ├── data_pipeline.py      # Main entry point for data preprocessing
    │   ├── data_types.py         # Core data structures for inputs/targets
    │   ├── process_utils.py      # Shared preprocessing utilities
    │   ├── process_transformer.py # Transformer-specific preprocessing
    │   ├── process_static.py     # Static embedding preprocessing
    │   └── validate_docker.py    # Validation script for Docker environment
    ├── models/                   # Model definitions and components
    └── cache/                    # Cached preprocessing results
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
chmod +x infrastructure/setup/*.sh
chmod +x infrastructure/teardown/*.sh
chmod +x infrastructure/utils/*.sh
chmod +x infrastructure/mgt/*.sh
```

## 1. Environment Configuration

### 1.1 Configuration File Setup

Create and configure your environment variables:

```bash
# Copy the template (don't edit the template directly)
cp config/.env.template config/.env

# Edit your .env file with your specific settings
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
IMAGE_NAME=eu.gcr.io/${PROJECT_ID}/tae-tpu:v1  # Docker image name with registry

# Service Account details
SERVICE_ACCOUNT_JSON=your-service-account.json  # JSON key filename
SERVICE_ACCOUNT_EMAIL=your-service-account@your-project.iam.gserviceaccount.com  # Service account email

# Dataset Configuration
# Format: DATASET_[KEY]_NAME = the dataset name/path on Hugging Face
DATASET_GUTENBERG_NAME="nbeerbower/gutenberg2-dpo"
DATASET_EMOTION_NAME="dair-ai/emotion"
```

### 1.2 Environment Variables

The following environment variables are critical for proper functioning:

| Variable | Description | Impact if Misconfigured |
|----------|-------------|-------------------------|
| PROJECT_ID | Google Cloud project identifier | All GCP operations will fail |
| TPU_ZONE | Zone where TPU is deployed | TPU creation and access will fail |
| CONTAINER_NAME | Name of Docker container | Scripts will look for wrong container |
| IMAGE_NAME | Full Docker image reference | Image building and pulling will fail |
| SERVICE_ACCOUNT_JSON | Path to service account key | Authentication will fail |

### 1.3 Service Account Setup

Your service account requires the following permissions:
- `roles/tpu.admin` - For creating and managing TPUs
- `roles/storage.admin` - For accessing GCS and Artifact Registry
- `roles/compute.admin` - For VM operations

## 2. Infrastructure Setup Process

### 2.1 Check for Available TPU Zones

Find a zone where your desired TPU type is available:

```bash
./infrastructure/setup/check_zones.sh
```

This script:
1. Authenticates with GCP using your service account
2. Lists available zones in your configured region
3. Checks each zone for your specified TPU type
4. Updates your `.env` file with the first available zone

**Key Parameters:**
- `TPU_REGION`: Target region to search in
- `TPU_TYPE`: Type of TPU you want to use

**Common Issues:**
- If no zones are found, try a different region
- TPU quotas might be exceeded in your project
- Some TPU types are only available in specific regions

### 2.2 Build and Push the Docker Image

Build your Docker image and push it to Google Container Registry:

```bash
./infrastructure/setup/setup_image.sh
```

This script:
1. Authenticates with Google Container Registry
2. Cleans up any existing containers/images with same name
3. Builds the Docker image using docker-compose
4. Pushes the image to GCR

**Key Docker Image Components:**
- Base: `python:3.11-slim`
- PyTorch with TPU support
- Required Python packages for transformer experiments
- TPU access configuration
- Volume mount points for data and code

**Potential Issues:**
- Docker build errors often relate to network connectivity or registry authentication
- Ensure your service account has proper GCR access
- Large dependencies may cause timeouts - adjust as needed

### 2.3 Set Up TPU VM and Pull Docker Image

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

**Critical Parameters:**
- `--privileged`: Required for TPU access
- `--net=host`: Required for network access
- Environment variables for TPU configuration:
  - `PJRT_DEVICE=TPU`
  - `XLA_USE_BF16=1`
  - `TPU_NAME=local` 
  - `TPU_LOAD_LIBRARY=0`
  - `TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so`
  - `NEXT_PLUGGABLE_DEVICE_USE_C_API=true`

## 3. Development Workflow

### 3.1 Working with Docker Container

The project uses three key management scripts to interact with the Docker container:

#### 3.1.1 mount.sh - Transferring Files to Container

```bash
# Mount all files
./infrastructure/mgt/mount.sh --all

# Mount specific Python file
./infrastructure/mgt/mount.sh example.py

# Mount specific directory
./infrastructure/mgt/mount.sh --dir data
```

**Functionality:**
- Checks if container is running; starts it if stopped
- Creates necessary directory structure in container
- Copies files from local machine to container
- Sets appropriate permissions for mounted files

**Key Flags:**
- `--all`: Mounts the entire src directory to container
- `--dir [directory]`: Mounts a specific directory and its contents
- No flags: Mounts all Python files in src directory

**Container Structure:**
The mount script creates and maintains the following structure:
```
/app/mount/src/          # Main mount directory
├── configs/             # Configuration files
├── datasets/            # Dataset files
│   ├── raw/             # Raw downloaded datasets
│   └── clean/           # Processed datasets
├── cache/               # Preprocessing cache
├── models/              # Model files
└── *.py                 # Python scripts
```

**Troubleshooting Mount Issues:**
If you encounter errors about "Unable to find image 'tae-tpu-container:latest' locally", verify that:
1. Your `.env` file contains the correct `CONTAINER_NAME` (should be `tae-tpu-container`)
2. Your docker-compose.yml has the same container name as in mount.sh
3. You can fix this by running: `docker tag eu.gcr.io/${PROJECT_ID}/tae-tpu:v1 tae-tpu-container:latest`

#### 3.1.2 run.sh - Executing Code in Container

```bash
# Run a specific Python file
./infrastructure/mgt/run.sh data/validate_docker.py

# Run with arguments
./infrastructure/mgt/run.sh data/data_pipeline.py --model all --dataset all
```

**Functionality:**
- Checks if file exists locally, mounts it if needed
- Locates the file within the container
- Executes the file with appropriate Python environment
- Captures and returns exit code for status checking

**Key Features:**
- Automatic file mounting if not present in container
- Proper argument passing to Python scripts
- Error handling and status reporting
- Output capture directly to terminal

#### 3.1.3 scrap.sh - Cleaning Up Container Files

```bash
# Remove all files
./infrastructure/mgt/scrap.sh --all

# Remove a specific directory
./infrastructure/mgt/scrap.sh --dir cache

# Remove specific files
./infrastructure/mgt/scrap.sh data/example.py models/test_model.py
```

**Functionality:**
- Confirms deletions with user to prevent accidental data loss
- Removes files or directories while preserving essential structure
- Handles error conditions gracefully
- Displays current files after operation

**Key Flags:**
- `--all`: Removes all files but preserves directory structure
- `--dir [directory]`: Removes a specific directory and its contents
- File arguments: Removes specific files

### 3.2 Validating the Docker Environment

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
- Proper functioning of the data_types module
- TPU availability (if running on TPU hardware)

### 3.3 Working with Data

The project includes a comprehensive data processing pipeline:

```bash
# Mount data processing files to Docker container
./infrastructure/mgt/mount.sh --dir data

# Download and preprocess datasets
./infrastructure/mgt/run.sh data/data_pipeline.py --start-stage download --end-stage download

# Run full preprocessing pipeline
./infrastructure/mgt/run.sh data/data_pipeline.py --model all --dataset all

# Run transformer preprocessing only
./infrastructure/mgt/run.sh data/data_pipeline.py --model transformer --dataset all

# Run static embedding preprocessing only
./infrastructure/mgt/run.sh data/data_pipeline.py --model static --dataset all
```

#### 3.3.1 Data Processing Pipeline Options

The data pipeline supports the following options:

- **Model and Dataset Selection**:
  - `--model [transformer|static|all]`: Select model type to process for
  - `--dataset [gutenberg|emotion|all]`: Select dataset to process

- **Pipeline Control**:
  - `--start-stage [download|tokenization|label_generation]`: Stage to start from
  - `--end-stage [download|tokenization|label_generation|all]`: Stage to end at
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
  - `--view`: View datasets instead of processing them
  - `--dataset-type [raw|clean|auto]`: Type of datasets to view
  - `--examples N`: Number of examples to show (default: 3)
  - `--detailed`: Show detailed information about examples

Processed datasets are saved to the `/app/mount/src/datasets/clean` directory in the Docker container.

### 3.4 Viewing Datasets

You can view the raw or processed datasets:

```bash
# View raw datasets
./infrastructure/mgt/run.sh data/data_pipeline.py --view --dataset-type raw

# View processed datasets
./infrastructure/mgt/run.sh data/data_pipeline.py --view --dataset-type clean

# View only transformer datasets with detailed information
./infrastructure/mgt/run.sh data/data_pipeline.py --view --model transformer --detailed

# View a specific dataset
./infrastructure/mgt/run.sh data/data_pipeline.py --view --dataset gutenberg
```

### 3.5 Directory Structure in Docker Container

All data processing happens within the Docker container with the following directory structure:

```
/app/mount/src/
├── configs/                # Configuration files
├── datasets/               # Dataset files
│   ├── raw/                # Raw downloaded datasets
│   └── clean/              # Processed datasets
│       ├── transformer/    # Transformer model datasets
│       └── static/         # Static embedding datasets
├── cache/prep/             # Preprocessing cache
├── models/prep/            # Preprocessing models (e.g., SentencePiece)
└── data/                   # Data processing scripts
```

## 4. Teardown Resources

When you're done with your TPU resources:

```bash
# Delete the TPU VM
./infrastructure/teardown/teardown_tpu.sh

# Delete the Docker images (local and GCR)
./infrastructure/teardown/teardown_image.sh
```

**Teardown Features:**
- Interactive confirmation to prevent accidental deletions
- Complete resource cleanup to avoid ongoing charges
- Proper GCP service disconnection
- Local Docker image cleanup

## 5. Troubleshooting Guide

### 5.1 Container Name Mismatch

If you encounter "Unable to find image 'tae-tpu-container:latest' locally" error:

```bash
# Quick fix: Tag the existing image with the name expected by the scripts
docker tag eu.gcr.io/${PROJECT_ID}/tae-tpu:v1 tae-tpu-container:latest

# Verify container exists
docker ps -a | grep tae-tpu
```

### 5.2 Docker Volume Issues

If container can't access mounted volumes:

```bash
# Check volume permissions
docker exec tae-tpu-container ls -la /app/mount

# Fix permissions if needed
docker exec tae-tpu-container chmod -R 777 /app/mount
```

### 5.3 TPU Connectivity Problems

If scripts can't connect to TPU:

```bash
# Verify TPU exists and is running
gcloud compute tpus tpu-vm list --zone=$TPU_ZONE

# Check TPU status
gcloud compute tpus tpu-vm describe $TPU_NAME --zone=$TPU_ZONE
```

### 5.4 Common Command Patterns

Here are some frequently used command patterns:

```bash
# Full data processing workflow
./infrastructure/mgt/mount.sh --dir data
./infrastructure/mgt/run.sh data/data_pipeline.py --model transformer --dataset gutenberg

# Validation and verification
./infrastructure/mgt/run.sh data/validate_docker.py
./infrastructure/mgt/run.sh example.py

# Clean up and restart
./infrastructure/mgt/scrap.sh --all
./infrastructure/teardown/teardown_tpu.sh
./infrastructure/setup/setup_tpu.sh
```

## 6. Additional Resources

- [Google Cloud TPU Documentation](https://cloud.google.com/tpu/docs)
- [PyTorch XLA Documentation](https://pytorch.org/xla/)
- [TPU Performance Guide](https://cloud.google.com/tpu/docs/performance-guide)
- [Docker with TPU Guide](https://cloud.google.com/tpu/docs/run-in-container)