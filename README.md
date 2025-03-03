# TPU Development Environment

This repository provides scripts and tools for setting up and managing Cloud TPU resources for TensorFlow development. The system includes scripts for creating TPU VMs, building Docker images with TPU support, setting up Google Cloud Storage buckets, and comprehensive monitoring tools.

## Prerequisites

Before using these scripts, ensure you have:

1. A Google Cloud Platform account with billing enabled
2. The [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) installed and configured
3. The Cloud TPU API enabled in your GCP project
4. Python 3.8+ installed

## Project Structure

```
project-root/
├── source/
│   ├── .env              # Environment variables configuration
│   └── [credentials]     # Service account key (if used)
├── src/
│   ├── setup/
│   │   ├── docker/
│   │   │   ├── Dockerfile        # TPU-enabled container definition
│   │   │   └── requirements.txt  # Python dependencies
│   │   ├── scripts/
│   │   │   ├── check_vm_versions.sh  # Helper for finding compatible TPU VM versions
│   │   │   ├── check_zones.sh        # Helper for finding TPU availability by zone
│   │   │   ├── setup_bucket.sh       # Create GCS bucket for data/logs
│   │   │   ├── setup_image.sh        # Build and push Docker image for TPU
│   │   │   └── setup_tpu.sh          # Create and configure TPU VM
│   ├── utils/
│   │   ├── common_logging.sh     # Shared logging and utility functions
│   │   ├── verify.sh             # Resource verification tools
│   │   └── monitors/             # Monitoring modules
│   └── teardown/
│       ├── teardown_bucket.sh    # Delete GCS bucket
│       ├── teardown_image.sh     # Remove Docker image
│       └── teardown_tpu.sh       # Delete TPU VM
├── dev/
│   ├── mgt/                      # Management utilities
│   │   ├── mount.sh              # Mount files to TPU VM
│   │   ├── run.sh                # Run code on TPU VM
│   │   ├── scrap.sh              # Clean up files from TPU VM
│   │   ├── synch.sh              # Synchronize code with TPU VM
│   │   └── mount_run_scrap.sh    # Combined mounting, running, and cleanup
│   ├── src/
│       ├── example.py            # Example TPU application
│       ├── start_monitoring.py   # Monitoring system entry point
│       └── utils/
│           ├── monitors/         # TPU and bucket monitoring modules
│           ├── logging/          # Logging utilities
│           └── backend/          # TensorBoard backend components
```

## Configuration

1. Copy the template configuration file:
   ```bash
   cp source/.env.template source/.env
   ```

2. Edit the `.env` file with your project-specific settings:
   ```
   # Project Configuration
   PROJECT_ID=your-gcp-project-id
   TPU_REGION=europe-west4
   TPU_ZONE=europe-west4-a
   BUCKET_REGION=europe-west4
   TPU_NAME=my-tpu-vm
   TPU_TYPE=v2-8

   # TPU and TensorFlow Configuration
   TF_VERSION=2.18.0
   TPU_VM_VERSION=tpu-vm-tf-2.18.0-pjrt-v5p-and-below

   # Cloud Storage
   BUCKET_NAME=your-gcp-project-id-tpu-bucket
   BUCKET_DATRAIN=gs://your-gcp-project-id-tpu-bucket/training-data/
   BUCKET_TENSORBOARD=gs://your-gcp-project-id-tpu-bucket/tensorboard-logs/

   # Service Account details (optional)
   SERVICE_ACCOUNT_JSON=your-service-account-key.json
   SERVICE_ACCOUNT_EMAIL=your-service-account@your-project.iam.gserviceaccount.com
   ```

## Pre-Deployment Checks

Before setting up resources, verify TPU availability and compatibility with these helper scripts:

### 1. Check TPU Zone Availability

Determine TPU availability in your selected region:

```bash
./src/setup/scripts/check_zones.sh
```

This script:
- Lists all zones in your configured region
- Checks each zone for your specified TPU type
- Updates your `.env` file with the optimal zone

### 2. Check TPU VM Version Compatibility

Find compatible TPU VM versions for your TensorFlow version:

```bash
./src/setup/scripts/check_vm_versions.sh
```

This script:
- Retrieves available TPU VM versions for your zone
- Identifies versions compatible with your TensorFlow version and TPU type
- Updates your `.env` file with the optimal VM version

## Setup Process

### 1. Create a GCS Bucket

```bash
./src/setup/scripts/setup_bucket.sh
```

This script:
- Creates a GCS bucket for storing training data and logs
- Sets up directories for training data and TensorBoard logs according to your `.env` configuration
- Configures appropriate permissions

### 2. Build and Push Docker Image

```bash
./src/setup/scripts/setup_image.sh
```

This script:
- Uses the Dockerfile in `src/setup/docker/` to build a container image with TensorFlow and TPU support
- Tags the image with your project ID
- Pushes it to Google Container Registry for use on your TPU VM

### 3. Create a TPU VM

```bash
./src/setup/scripts/setup_tpu.sh
```

This script:
- Creates a new TPU VM with the configuration from your `.env` file
- Sets up Docker permissions on the VM
- Configures service account authentication (if specified)
- Sets TPU environment variables

## Verification

After setup, verify your resources with the verification tool:

```bash
# Verify all components
./src/utils/verify.sh --env --tpu --image --bucket

# Or verify individual components
./src/utils/verify.sh --env   # Check environment variables
./src/utils/verify.sh --tpu   # Verify TPU hardware access
./src/utils/verify.sh --image # Verify Docker image and container TPU access
./src/utils/verify.sh --bucket # Verify GCS bucket configuration
```

## Code Management

The `dev/mgt` directory provides utilities for managing code on your TPU VM:

### Mounting Files

Mount files from your local `dev/src` directory to the TPU VM:

```bash
# Mount specific files
./dev/mgt/mount.sh example.py

# Mount multiple files
./dev/mgt/mount.sh example.py utils/helper.py

# Mount all files in dev/src
./dev/mgt/mount.sh --all

# Mount just the utils directory
./dev/mgt/mount.sh --utils
```

### Running Code on TPU VM

Execute Python or shell script files on the TPU VM:

```bash
# Run a Python file
./dev/mgt/run.sh example.py

# Run a shell script
./dev/mgt/run.sh run_example.sh

# Run with arguments
./dev/mgt/run.sh example.py --epochs 10

# Verify TPU hardware access
./dev/mgt/run.sh --verify
```

### Synchronizing Code Changes

Continuously synchronize code changes to the TPU VM:

```bash
# One-time synchronization of all Python files
./dev/mgt/synch.sh

# Watch for changes and sync automatically
./dev/mgt/synch.sh --watch

# Sync and restart container automatically
./dev/mgt/synch.sh --watch --restart

# Sync specific files only
./dev/mgt/synch.sh --specific model.py train.py
```

### Clean Up Files

Remove files from the TPU VM when no longer needed:

```bash
# Remove specific files
./dev/mgt/scrap.sh example.py

# Remove all files
./dev/mgt/scrap.sh --all
```

### Combined Operations

Mount, run, and optionally clean up files in a single operation:

```bash
# Mount, run, and keep files
./dev/mgt/mount_run_scrap.sh example.py

# Mount, run with arguments, and clean up
./dev/mgt/mount_run_scrap.sh --clean example.py --epochs 10
```

## Resource Monitoring

The system includes comprehensive monitoring tools for TPU VMs and GCS buckets:

### Starting Monitoring

```bash
# Start monitoring system
python dev/src/start_monitoring.py start

# With custom configuration
python dev/src/start_monitoring.py start --log-dir logs --interval 30 --bucket your-bucket-name
```

This:
- Starts TPU hardware monitoring (CPU, memory, TPU utilization)
- Monitors GCS bucket usage and transfer rates
- Collects metrics for TensorBoard visualization

### Running Example with Monitoring

```bash
# Run example with monitoring
./dev/src/run_example.sh --bucket your-bucket-name --matrix-size 5000
```

This script:
- Starts monitoring in the background
- Runs an example TPU workload
- Collects metrics during execution
- Generates a report after completion

### Generating Reports

```bash
# Generate monitoring report
python dev/src/start_monitoring.py report --output-dir logs/reports
```

## TensorBoard Integration

The system includes a complete TensorBoard integration with a backend API:

### Setting Up TensorBoard Backend

```bash
# Set up TensorBoard backend
./dev/src/utils/backend/tensorboard/setup_backend.sh
```

This script:
- Builds a Docker image for TensorBoard
- Sets up a service account with appropriate permissions
- Deploys TensorBoard to Cloud Run (optional)

### Starting TensorBoard API Server

```bash
# Start TensorBoard API server
python dev/src/start_webapp.py --port 5000
```

This:
- Starts a REST API server for accessing monitoring data
- Provides endpoints for querying TPU metrics
- Allows integration with custom dashboards

## Teardown Process

When you're finished with your TPU resources, use these scripts to clean up:

```bash
# Delete TPU VM
./src/teardown/teardown_tpu.sh

# Remove Docker image
./src/teardown/teardown_image.sh

# Delete GCS bucket
./src/teardown/teardown_bucket.sh
```

## Troubleshooting

### TPU VM Creation Issues

- Check TPU availability in your zone with `check_zones.sh`
- Ensure you have enough quota for the requested TPU type
- Verify the TPU VM version is compatible with your TPU type using `check_vm_versions.sh`

### Docker Container TPU Access Issues

- Ensure the container is run with `--privileged` and `--device=/dev/accel0`
- Verify the TPU driver is mounted correctly with `-v /lib/libtpu.so:/lib/libtpu.so`
- Check that all required environment variables are set

### Authentication Issues

- Verify your service account has the required permissions
- Ensure the service account key file is correctly referenced in the `.env` file
- Run `gcloud auth list` to check active credentials