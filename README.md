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

## Project Structure
```
.
├── .gitattributes          # Git attributes configuration
├── .gitignore              # Git ignore configuration
├── README.md               # Project documentation
├── dev/                    # Development environment for rapid iteration
│   ├── src/                # Development code to run on TPU
│   │   └── example.py      # Example file for TPU code development
│   ├── mgt/                # Management scripts for development
│   │   ├── mount.sh        # Script to mount files to TPU VM
│   │   ├── run.sh          # Script to execute files on TPU VM
│   │   ├── scrap.sh        # Script to remove files from TPU VM
│   │   └── run_all.sh      # All-in-one script to mount, run, and clean up
│   └── README.md           # Documentation for the development workflow
├── setup/                  # Setup and teardown scripts
│   ├── check_zones.sh      # Script to find available TPU zones
│   ├── setup_bucket.sh     # Script to create GCS bucket
│   ├── setup_image.sh      # Script to build and push Docker image to GCR
│   ├── setup_tpu.sh        # Script to create TPU VM and pull Docker image
│   ├── teardown_bucket.sh  # Script to delete GCS bucket
│   ├── teardown_image.sh   # Script to clean up Docker images locally and in GCR
│   ├── teardown_tpu.sh     # Script to delete TPU VM
│   └── docker/             # Docker configuration
│       ├── Dockerfile      # Docker image definition
│       └── requirements.txt # Python dependencies
├── src/                    # Source code and execution scripts
│   ├── verify.py           # Comprehensive TPU verification utility script
│   └── run_verification.sh # Script to verify PyTorch/XLA on TPU
└── source/                 # Configuration and credential files
    ├── .env                # Environment variables and configuration
    └── service-account.json # Service account key (replace with your own)
```

## Setting Up the Environment

Before running transformer ablation experiments, you'll need to set up the Google Cloud TPU environment. The following instructions walk you through this process.

### Configuration

Before running the scripts, update the `source/.env` file with your specific settings:

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

# Debug Configuration
TPU_DEBUG=true  # Set to true for verbose logging, false for minimal logging

# Optional TPU initialization arguments
# LIBTPU_INIT_ARGS=--xla_jf_conv_full_precision=true
```

### Complete Workflow for TPU Setup and Execution

Follow these steps in order to set up your TPU environment and prepare for experiments:

#### 1. Preparation

Make all scripts executable:
```bash
chmod +x setup/*.sh
chmod +x setup/docker/*.sh
chmod +x src/*.sh
chmod +x dev/mgt/*.sh
```

#### 2. Check for Available TPU Zones

First, find a zone where your desired TPU type is available:

```bash
# Run the zone checker
./setup/check_zones.sh
```

This script will:
- Check all zones in your configured TPU_REGION
- Search for availability of your specified TPU_TYPE
- Automatically update your .env file with the correct TPU_ZONE

#### 3. Set Up Google Cloud Storage Bucket

Create a bucket for storing experiment data, model checkpoints, and logs:

```bash
./setup/setup_bucket.sh
```

#### 4. Build and Push the Docker Image

Build your Docker image and push it to Google Container Registry:

```bash
./setup/setup_image.sh
```

#### 5. Set Up TPU VM and Pull Docker Image

Create the TPU VM and pull the Docker image:

```bash
./setup/setup_tpu.sh
```

#### 6. Verify TPU Environment

Verify that PyTorch and XLA are properly installed and can access the TPU:

```bash
./src/run_verification.sh
```

### Development Workflow

For rapid development and testing without rebuilding the Docker image:

```bash
# Mount a Python script to the TPU VM
./dev/mgt/mount.sh example.py

# Run the script on the TPU VM
./dev/mgt/run.sh example.py

# Or use the all-in-one script (mount, run, and optionally clean up)
./dev/mgt/run_all.sh example.py
./dev/mgt/run_all.sh example.py --clean  # Clean up after running

# Remove scripts from the TPU VM when done
./dev/mgt/scrap.sh example.py
# Or remove all mounted scripts
./dev/mgt/scrap.sh -all
```

The development workflow allows you to:
1. Create or modify Python files in the `dev/src` directory
2. Mount them to the TPU VM using the `mount.sh` script
3. Execute them on the TPU VM using the `run.sh` script
4. Clean up using the `scrap.sh` script when done

This approach enables rapid iteration without rebuilding Docker images.

### Clean Up Resources When Finished

When you're done, clean up resources in this order:

```bash
# Delete the TPU VM
./setup/teardown_tpu.sh

# Delete the Docker images (local and GCR)
./setup/teardown_image.sh

# Delete the GCS bucket (will prompt for confirmation)
./setup/teardown_bucket.sh
```

## System Requirements

- Docker Desktop installed and running
- Google Cloud SDK installed and configured
- Service account with necessary permissions:
  - Compute Admin
  - Storage Admin
  - Service Account User
  - Container Registry access
- Google Cloud project with TPU API enabled

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
