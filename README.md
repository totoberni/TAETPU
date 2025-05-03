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
│   │   ├── mount.sh              # Script to mount files to Docker Image
│   │   ├── run.sh                # Script to execute files through Docker Image
│   │   └── scrap.sh              # Script to remove files from Docker Image
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
    │   ├── processing_utils.py   # Shared preprocessing utilities
    │   ├── process_transformer.py # Transformer-specific preprocessing
    │   └── process_static.py     # Static embedding preprocessing
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

## 1. Configuration

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
PROJECT_ID=your-project-id
TPU_REGION=europe-west4
TPU_ZONE=europe-west4-a
TPU_NAME=your-tpu-name
TPU_TYPE=v2-8
RUNTIME_VERSION=tpu-ubuntu2204-base

# Service Account details
SERVICE_ACCOUNT_JSON=your-service-account.json
SERVICE_ACCOUNT_EMAIL=your-service-account@your-project.iam.gserviceaccount.com

# Dataset Configuration
# Format: DATASET_[KEY]_NAME = the dataset name/path on Hugging Face
DATASET_GUTENBERG_NAME="nbeerbower/gutenberg2-dpo"
DATASET_EMOTION_NAME="dair-ai/emotion"
```

## 2. Setup Process

### 2.1 Check for Available TPU Zones

Find a zone where your desired TPU type is available:

```bash
./infrastructure/setup/check_zones.sh
```

### 2.2 Build and Push the Docker Image

Build your Docker image and push it to Google Container Registry:

```bash
./infrastructure/setup/setup_image.sh
```

### 2.3 Set Up TPU VM and Pull Docker Image

Create the TPU VM, pull the Docker image, and start the container:

```bash
./infrastructure/setup/setup_tpu.sh
```

## 3. Development Workflow

### 3.1 Working with TPU VM

Mount and run files on the TPU VM:

```bash
# Mount files to TPU VM
./infrastructure/mgt/mount.sh example.py

# Run a file on TPU VM
./infrastructure/mgt/run.sh example.py

# Clean up files from TPU VM (preserves critical directory structure)
./infrastructure/mgt/scrap.sh --all
```

The management scripts now intelligently handle the required directory structure:

- `mount.sh` - Creates/maintains directories when mounting files
- `run.sh` - Validates directories before running data processing scripts
- `scrap.sh` - Removes files while preserving essential directory structure

### 3.2 Working with Data

The project includes a comprehensive data processing pipeline:

```bash
# Mount data processing files to TPU VM
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

#### Data Processing Pipeline Options

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
  - `--dataset-type [raw|processed|auto]`: Type of datasets to view
  - `--examples N`: Number of examples to show (default: 3)
  - `--detailed`: Show detailed information about examples

Processed datasets are saved to the `/app/mount/src/datasets/clean` directory in the Docker container.

### 3.3 Viewing Datasets

You can view the raw or processed datasets:

```bash
# View raw datasets
./infrastructure/mgt/run.sh data/data_pipeline.py --view --dataset-type raw

# View processed datasets
./infrastructure/mgt/run.sh data/data_pipeline.py --view --dataset-type processed

# View only transformer datasets with detailed information
./infrastructure/mgt/run.sh data/data_pipeline.py --view --model transformer --detailed

# View a specific dataset
./infrastructure/mgt/run.sh data/data_pipeline.py --view --dataset gutenberg
```

## 4. Teardown Resources

When you're done with your TPU resources:

```bash
# Delete the TPU VM
./infrastructure/teardown/teardown_tpu.sh

# Delete the Docker images (local and GCR)
./infrastructure/teardown/teardown_image.sh
```

## 5. Additional Resources

- [Google Cloud TPU Documentation](https://cloud.google.com/tpu/docs)
- [PyTorch XLA Documentation](https://pytorch.org/xla/)
- [TPU Performance Guide](https://cloud.google.com/tpu/docs/performance-guide)