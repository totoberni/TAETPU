# Transformer Ablation Experiment on Google Cloud TPU (with PyTorch) 

This repository contains a complete setup for running PyTorch on Google Cloud TPU VMs using Docker. It demonstrates how to set up a TPU VM, build and deploy a Docker container with PyTorch/XLA support, and run a simple test script that validates TPU functionality.

## Project Structure
```
.
├── .gitattributes          # Git attributes configuration
├── .gitignore              # Git ignore configuration
├── README.md               # Project documentation
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
│   ├── main.py             # Main Python script for TPU execution
│   ├── run_main.sh         # Script to run main.py on TPU inside Docker
│   ├── run_verification.sh # Script to verify PyTorch/XLA on TPU
│   └── verify.py           # TPU verification utility script
└── source/                 # Configuration and credential files
    ├── .env                # Environment variables and configuration
    └── service-account.json  # Service account key (replace with your own)
```

## File Descriptions

- `source/.env`: Contains all configuration variables including project ID, TPU specifications, and service account details
- `src/main.py`: PyTorch script that verifies TPU connectivity and performs basic tensor operations
- `src/verify.py`: Python script that performs TPU verification and compatibility checks
- `src/run_main.sh`: Handles the execution of main.py inside a Docker container on the TPU VM
- `src/run_verification.sh`: Verifies PyTorch/XLA installation and TPU connectivity inside the Docker container
- `setup/check_zones.sh`: Finds available TPU zones in your configured region and updates the .env file automatically
- `setup/setup_bucket.sh`: Creates a Google Cloud Storage bucket for TPU-related storage
- `setup/setup_image.sh`: Builds the Docker image locally and pushes it to Google Container Registry
- `setup/setup_tpu.sh`: Provisions a TPU VM and pulls the Docker image
- `setup/teardown_bucket.sh`: Safely deletes the GCS bucket and its contents
- `setup/teardown_image.sh`: Removes Docker images both locally and from Google Container Registry
- `setup/teardown_tpu.sh`: Deletes the TPU VM instance
- `setup/docker/Dockerfile`: Defines the Docker image with PyTorch and XLA support
- `setup/docker/requirements.txt`: Lists the Python packages to be installed in the Docker image

## Configuration

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

## Complete Workflow for TPU Setup and Execution

Follow these steps in order to set up your TPU environment and run the PyTorch example:

### 1. Preparation

Make all scripts executable:
```bash
chmod +x setup/*.sh
chmod +x setup/docker/*.sh
chmod +x src/*.sh
```

### 2. Check for Available TPU Zones

First, find a zone where your desired TPU type is available:

```bash
# Run the zone checker
./setup/check_zones.sh
```

This script will:
- Check all zones in your configured TPU_REGION
- Search for availability of your specified TPU_TYPE
- Automatically update your .env file with the correct TPU_ZONE

### 3. Set Up Google Cloud Storage Bucket

Create a bucket for storing TPU-related files:

```bash
./setup/setup_bucket.sh
```

This step is optional but recommended for storing model checkpoints, data, and logs.

### 4. Build and Push the Docker Image

Build your Docker image and push it to Google Container Registry:

```bash
./setup/setup_image.sh
```

This script will:
- Build the Docker image locally with tag `tpu-hello-world:v1`
- Configure Docker to authenticate with Google Container Registry
- Tag the image for GCR as `gcr.io/[YOUR-PROJECT-ID]/tpu-hello-world:v1`
- Push the image to GCR

### 5. Set Up TPU VM and Pull Docker Image

Create the TPU VM and pull the Docker image:

```bash
./setup/setup_tpu.sh
```

This script will:
- Create a TPU VM using the `tpu-ubuntu2204-base` image
- Configure Docker permissions on the TPU VM
- Set up authentication for Google Container Registry
- Pull your Docker image from Google Container Registry onto the TPU VM

### 6. Verify PyTorch/XLA Installation

Verify that PyTorch and XLA are properly installed and can access the TPU:

```bash
./src/run_verification.sh
```

This important verification step ensures:
- PyTorch is correctly installed
- PyTorch/XLA can detect and access TPU devices
- The Docker container is working as expected

### 7. Run the Hello World Example

Execute the PyTorch script inside the Docker container on the TPU VM:

```bash
./src/run_main.sh
```

This script runs the main.py PyTorch example to demonstrate basic TPU operations.

### 8. Clean Up Resources When Finished

When you're done, clean up resources in this order:

```bash
# Delete the TPU VM
./setup/teardown_tpu.sh

# Delete the Docker images (local and GCR)
./setup/teardown_image.sh

# Delete the GCS bucket (will prompt for confirmation)
./setup/teardown_bucket.sh
```

## Accessing the TPU VM Directly

For debugging purposes or custom operations, you may want to access the TPU VM directly:

### SSH Access to the TPU VM

Access your TPU VM via SSH using the Google Cloud CLI:

```bash
# Load environment variables
source source/.env

# SSH into the TPU VM
gcloud compute tpus tpu-vm ssh "$TPU_NAME" \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID"
```

### Working with Docker on the TPU VM

Once connected to the TPU VM, you can work with Docker directly:

```bash
# List available Docker images
docker images

# Run a container with an interactive shell
docker run --rm -it --privileged \
  --device=/dev/accel0 \
  -e PJRT_DEVICE=TPU \
  -e XLA_USE_BF16=1 \
  gcr.io/<your-project-id>/tpu-hello-world:v1 /bin/bash

# Check TPU accessibility
ls -la /dev/accel*
```

### Transferring Files to/from the TPU VM

Transfer files between your local machine and the TPU VM:

```bash
# From local to TPU VM
gcloud compute tpus tpu-vm scp local_file.py "$TPU_NAME":/home/username/ \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID"

# From TPU VM to local
gcloud compute tpus tpu-vm scp "$TPU_NAME":/home/username/remote_file.py ./local_folder/ \
    --zone="$TPU_ZONE" \
    --project="$PROJECT_ID"
```

## Troubleshooting

Common issues and solutions:

1. **Docker Permission Issues on TPU VM**
   - This is the most common issue. If you see "permission denied" errors:
   - The setup_tpu.sh script attempts to add your user to the docker group
   - You may need to SSH into the TPU VM and run `sudo usermod -aG docker $USER` manually
   - Log out and log back in to apply group changes
   - As a fallback, the scripts will attempt to use `sudo docker` when necessary

2. **Docker Image Build Fails**
   - Check your Docker Desktop is running
   - Ensure you have internet access for downloading packages
   - Verify that you're building from the project root directory
   - Run `./teardown_image.sh` to clean up and try again

3. **Docker Image Push Fails**
   - Check that you've run `gcloud auth configure-docker`
   - Verify you have proper permissions to your Google Cloud project
   - Ensure your project has Container Registry API enabled

4. **TPU Creation Fails**
   - Verify quota availability in your region
   - Check if the TPU type is available in selected zone (use `check_zones.sh`)
   - Ensure TPU API is enabled

5. **Verification Script Fails**
   - Check that the Docker image was successfully pulled to the TPU VM
   - Verify the TPU VM has internet access
   - Ensure the PyTorch/XLA version is compatible with your TPU type
   - Look for TPU device detection issues at `/dev/accel*`
   - Increase debugging with `TPU_DEBUG=true` in the .env file

6. **Main Script Fails**
   - Look for Python errors in the output
   - Check that tensor operations are properly configured for TPU
   - Verify environment variables are properly set in the Docker container
   - Try rerunning the verification script first to confirm TPU accessibility

7. **Authentication Errors**
   - Verify service account JSON file path
   - Check service account permissions
   - Ensure Google Cloud SDK is properly configured
   - TPU VM may need to be restarted after authentication setup

8. **PyTorch/XLA Deprecation Warnings**
   - We've fixed the deprecated `devkind` parameter in our TPU detection logic
   - You may still see warnings about `XLA_USE_BF16` which will be deprecated in future PyTorch versions
   - It's recommended to use explicit model type conversion rather than relying on global flags

## System Requirements

- Docker Desktop installed and running
- Google Cloud SDK installed and configured
- Service account with necessary permissions:
  - Compute Admin
  - Storage Admin
  - Service Account User
  - Container Registry access
- Google Cloud project with TPU API enabled

## Security Notes

- Service account JSON files are automatically ignored by git
- Bucket access is configured with uniform bucket-level access
- All scripts verify credential existence before execution
- Service account authentication is only attempted if credentials are provided

## Cross-Platform Compatibility Notes

- All scripts are tested on Linux, macOS, and Windows (via WSL/Git Bash)
- Special characters are avoided in output messages for maximum terminal compatibility
- Windows users should run scripts through Git Bash or WSL for best compatibility
- Different sed syntax is handled for macOS vs. Linux environments

## Additional Resources

For more information, refer to:
- [Google Cloud TPU Documentation](https://cloud.google.com/tpu/docs)
- [PyTorch XLA Documentation](https://pytorch.org/xla/)
- [TPU Performance Guide](https://cloud.google.com/tpu/docs/performance-guide)
- [TPU VM Documentation](https://cloud.google.com/tpu/docs/run-calculation-pytorch)
- [Docker Documentation](https://docs.docker.com/)
- [Google Container Registry Documentation](https://cloud.google.com/container-registry/docs)
