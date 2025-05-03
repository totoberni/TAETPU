# Docker Volume Management Improvements

This document outlines the improvements made to implement best practices for Docker volume management across the TAETPU project.

## Key Improvements

1. **Consistent Container Naming**: Fixed container naming inconsistency by using environment variables consistently across all scripts.
2. **Container Name Mismatch Detection**: Added automatic detection and resolution of container name mismatches.
3. **Flexible Volume Management**: Added support for both host directory mounts and Docker named volumes.
4. **Improved Directory Structure**: Created proper directory structure for all volume types.
5. **Enhanced Script Options**: Added new command-line options for script flexibility.
6. **Better Documentation**: Added detailed README files for each volume type.

## Docker Disaster Averted: Container Name Mismatch Fixes

One of the most common issues with Docker-based TPU projects is container name inconsistency. We've implemented several mechanisms to automatically detect and fix this problem:

### Container Name Mismatch Detection

Added a `check_container_name_mismatch()` function to `common.sh` that:
- Detects when expected container names don't match actual container names
- Automatically creates image aliases using `docker tag` to fix mismatches
- Works with both running and stopped containers
- Searches for similarly-named containers using pattern matching

### Automatic Image Naming

All scripts now use a consistent approach to container and image naming:
- Use `CONTAINER_NAME` from environment variables (defaults to `tae-tpu-container`)
- Use `CONTAINER_TAG` from environment variables (defaults to `latest`)
- Use `IMAGE_NAME` from environment variables (defaults to `eu.gcr.io/${PROJECT_ID}/tae-tpu:v1`)

### Fallback Mechanisms

All management scripts (`mount.sh`, `run.sh`, `scrap.sh`) now implement multiple fallback mechanisms:
- Try alternate image names if primary name fails
- Create aliases automatically when mismatches detected
- Provide detailed error messages with explicit resolution steps

## Script Updates

### 1. docker-compose.yml

- Updated to use environment variables consistently
- Added proper defaults for container and image names
- Set proper TPU environment variables

```yaml
version: '3'
services:
  transformer-ablation:
    image: ${IMAGE_NAME:-eu.gcr.io/${PROJECT_ID}/tae-tpu:v1}
    container_name: ${CONTAINER_NAME:-tae-tpu-container}
    privileged: true
    network_mode: "host"
    environment:
      - PJRT_DEVICE=TPU
      # ... additional TPU environment variables
```

### 2. setup_tpu.sh

- Improved TPU VM creation with proper environment variable checks
- Added container name consistency fixes
- Enhanced Docker volume creation for named volumes
- Added directory structure creation inside the container

### 3. mount.sh

- Added container name mismatch detection and resolution
- Improved volume management with both host directories and named volumes
- Added better error handling and container recreation options

### 4. run.sh

- Added container name mismatch detection and resolution
- Improved file path handling for consistent execution
- Automatic file mounting if not found in container

### 5. scrap.sh

- Added container name mismatch detection and resolution
- Improved safety checks for file removal
- Better status reporting after operations

### 6. common.sh

- Added `check_container_name_mismatch()` function to detect and fix naming issues
- Improved logging and error reporting
- Enhanced environment variable management

## New Environment Variables

Added to the .env.template file:

```
# Container Configuration 
CONTAINER_NAME=tae-tpu-container
CONTAINER_TAG=latest
IMAGE_NAME=eu.gcr.io/${PROJECT_ID}/tae-tpu:v1

# Volume Configurations
HOST_SRC_DIR=/tmp/tae_src
HOST_DATASETS_DIR=/path/to/datasets
HOST_MODELS_DIR=/path/to/models
HOST_CHECKPOINTS_DIR=/path/to/checkpoints
HOST_LOGS_DIR=/path/to/logs
HOST_RESULTS_DIR=/path/to/results

# Volume Management Options
USE_NAMED_VOLUMES=false
VOLUME_PREFIX=tae
```

## Usage Examples

### Handling Container Name Mismatches

If you encounter "Unable to find image 'tae-tpu-container:latest' locally" error:

```bash
# The scripts will now automatically detect and fix this issue
./infrastructure/mgt/mount.sh --all

# Or you can manually create an alias (no longer needed but included for reference)
docker tag tpu_container:latest tae-tpu-container:latest
```

### Host Directory Mounting (Default)

```bash
# Mount files using host directories
./infrastructure/mgt/mount.sh --type src example.py
./infrastructure/mgt/mount.sh --all
./infrastructure/mgt/mount.sh --dir data
```

### Named Volume Mounting

```bash
# Mount files using Docker named volumes
./infrastructure/mgt/mount.sh --named-volumes --type src example.py
./infrastructure/mgt/mount.sh --named-volumes --all
```

## Best Practices Implemented

1. **Separation of Concerns**: Clear separation between different data types (input datasets, model checkpoints, logs, results)
2. **Consistent Naming**: Consistent naming patterns across all scripts and files
3. **Environment Variables**: Use of environment variables for configuration
4. **Flexible Approach**: Support for both named volumes and host directories
5. **Proper Permissions**: Setting appropriate file permissions
6. **Error Handling**: Improved error handling and logging
7. **Cleanup**: Proper cleanup operations to avoid leftover files
8. **Automatic Recovery**: Self-healing from common Docker configuration issues 