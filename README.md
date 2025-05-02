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
    └── data/                     # Data processing and management
        └── data_import.py        # Script to download and process datasets
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

# Clean up files from TPU VM
./infrastructure/mgt/scrap.sh --all
```

### 3.2 Working with Data

The project includes a data import script for downloading and processing datasets:

```bash
# Mount the data import script to TPU VM
./infrastructure/mgt/mount.sh data/data_import.py

# Run the data import script on TPU VM
./infrastructure/mgt/run.sh data/data_import.py

# Run with specific options
./infrastructure/mgt/run.sh data/data_import.py --force --gutenberg-only
```

The data import script supports the following options:
- `--force`: Force overwrite existing datasets without confirmation
- `--gutenberg-only`: Only process the gutenberg dataset
- `--emotion-only`: Only process the emotion dataset

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