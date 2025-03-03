# TPU Development Environment

This repository provides scripts and tools for setting up and managing Cloud TPU resources for TensorFlow development. The system includes scripts for creating TPU VMs, building Docker images with TPU support, and setting up Google Cloud Storage buckets.

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
│   │   └── verify.sh             # Resource verification tools
│   └── teardown/
│       ├── teardown_bucket.sh    # Delete GCS bucket
│       ├── teardown_image.sh     # Remove Docker image
│       └── teardown_tpu.sh       # Delete TPU VM
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

3. Find the appropriate TPU zone and VM version:
   ```bash
   ./src/setup/scripts/check_zones.sh
   ./src/setup/scripts/check_vm_versions.sh
   ```

## Setup Process

### 1. Create a TPU VM

```bash
./src/setup/scripts/setup_tpu.sh
```

This script:
- Creates a new TPU VM with the configuration from your `.env` file
- Sets up Docker permissions on the VM
- Configures service account authentication (if specified)
- Sets TPU environment variables

### 2. Build and Push Docker Image

```bash
./src/setup/scripts/setup_image.sh
```

This script:
- Uses the Dockerfile in `src/setup/docker/` to build a container image
- Tags the image with your project ID and pushes it to Google Container Registry

### 3. Create GCS Bucket

```bash
./src/setup/scripts/setup_bucket.sh
```

This script:
- Creates a GCS bucket for storing training data and logs
- Sets up directories for training data and TensorBoard logs

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

## Using the TPU VM

### Connecting to the TPU VM

```bash
gcloud compute tpus tpu-vm ssh ${TPU_NAME} --zone=${TPU_ZONE} --project=${PROJECT_ID}
```

### Running Containers with TPU Access

```bash
docker run --rm --privileged \
  --device=/dev/accel0 \
  -e PJRT_DEVICE=TPU \
  -e XLA_USE_BF16=1 \
  -e TPU_NAME=local \
  -e NEXT_PLUGGABLE_DEVICE_USE_C_API=true \
  -e TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so \
  -v /lib/libtpu.so:/lib/libtpu.so \
  -v /path/to/your/code:/app/code \
  gcr.io/${PROJECT_ID}/tpu-hello-world:v1 \
  python /app/code/your_script.py
```

### Running a Simple TPU Test

To confirm TensorFlow can access the TPU, run:

```python
import tensorflow as tf

# Check available TPU cores
tpu_cores = tf.config.list_logical_devices('TPU')
print(f"TensorFlow can access {len(tpu_cores)} TPU cores")

# Run a simple computation
@tf.function
def add_fn(x, y):
    return x + y

resolver = tf.distribute.cluster_resolver.TPUClusterResolver()
tf.config.experimental_connect_to_cluster(resolver)
tf.tpu.experimental.initialize_tpu_system(resolver)
strategy = tf.distribute.TPUStrategy(resolver)

x = tf.constant(1.0)
y = tf.constant(1.0)
result = strategy.run(add_fn, args=(x, y))
print(result)
```

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