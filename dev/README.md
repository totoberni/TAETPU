# TPU Development Environment

This directory provides a streamlined development environment for working with TPU code. It allows you to quickly iterate on code without needing to rebuild Docker images.

## Purpose

The traditional workflow for developing code on TPUs involves:
1. Writing code
2. Building a Docker image
3. Pushing the image to a registry
4. Pulling the image on the TPU VM
5. Running the code

This process is time-consuming and inefficient for rapid development. This directory provides an alternative approach that mounts code directly to the TPU VM's Docker container, enabling immediate testing of changes.

## Directory Structure

- `dev/`: Root of the development environment
  - `src/`: Contains development code (Python scripts to run on TPU)
  - `mgt/`: Contains management scripts for the development environment
    - `mount.sh`: Script to mount files to the TPU VM
    - `scrap.sh`: Script to remove files from the TPU VM
    - `run.sh`: Script to execute mounted files on the TPU VM
    - `mount_run_scrap.sh`: All-in-one script to mount, run, and optionally clean up files
    - `sync_code.sh`: Script for syncing and watching code changes (CI/CD integration)

## How to Use

### Creating Python Scripts

1. Create your Python scripts in the `dev/src/` directory
2. Use standard Python libraries and TPU-specific code as needed
3. Ensure your code is compatible with the Docker image used on the TPU VM

### Using Management Scripts

#### Mounting Files to TPU VM

```bash
# Mount a specific file to the TPU VM
./dev/mgt/mount.sh example.py

# Mount multiple files to the TPU VM
./dev/mgt/mount.sh model.py train.py utils.py

# Mount all Python files to the TPU VM
./dev/mgt/mount.sh --all
```

#### Running Files on TPU VM

```bash
# Run a mounted file on the TPU VM
./dev/mgt/run.sh example.py

# Run multiple files sequentially
./dev/mgt/run.sh preprocess.py train.py

# Run a file with arguments
./dev/mgt/run.sh model.py --epochs 10 --batch_size 32
```

#### Removing Files from TPU VM

```bash
# Remove a specific file from the TPU VM
./dev/mgt/scrap.sh example.py

# Remove multiple files from the TPU VM
./dev/mgt/scrap.sh model.py train.py

# Remove all files from the TPU VM
./dev/mgt/scrap.sh --all
```

#### All-in-One Workflow (Mount, Run, Clean)

```bash
# Mount, run, and keep example.py
./dev/mgt/mount_run_scrap.sh example.py

# Mount, run, and clean up model.py
./dev/mgt/mount_run_scrap.sh model.py --clean

# Process multiple files sequentially
./dev/mgt/mount_run_scrap.sh preprocess.py train.py

# Pass arguments to the Python script
./dev/mgt/mount_run_scrap.sh train.py --epochs 10
```

#### Continuous Code Synchronization (CI/CD)

```bash
# Sync all files in dev/src to TPU VM
./dev/mgt/sync_code.sh

# Sync all files and restart the container
./dev/mgt/sync_code.sh --restart

# Watch for changes and sync automatically
./dev/mgt/sync_code.sh --watch

# Watch for changes and restart container after each sync
./dev/mgt/sync_code.sh --watch --restart
```

## Example Workflow

### Basic Workflow

1. Create a new model in `dev/src/model.py`
2. Mount the file to the TPU VM: `./dev/mgt/mount.sh model.py`
3. Run the file on the TPU VM: `./dev/mgt/run.sh model.py`
4. Make changes to `model.py`
5. Mount the file again to update it on the TPU VM: `./dev/mgt/mount.sh model.py`
6. Run the updated file: `./dev/mgt/run.sh model.py`
7. When done, clean up: `./dev/mgt/scrap.sh model.py`

### Simplified Workflow with All-in-One Script

1. Create a new model in `dev/src/model.py`
2. Mount, run, and optionally clean up in one step: `./dev/mgt/mount_run_scrap.sh model.py [--clean]`
3. Make changes to `model.py`
4. Repeat step 2 to test the changes

### Continuous Development Workflow (CI/CD)

1. Create your Python files in `dev/src/`
2. Start the sync watcher: `./dev/mgt/sync_code.sh --watch --restart`
3. Make changes to your files - they will be automatically synced and the container restarted
4. Run your code on the TPU: `./dev/mgt/run.sh yourfile.py`
5. Continue making changes without needing to manually sync

## Creating Custom Scripts

You can create additional scripts in the `dev/src/` directory as needed for your development workflow. These might include:

- Model architecture definitions
- Training scripts
- Evaluation scripts
- Data processing utilities
- Ablation study scripts

## Integrating with Main Codebase

Once you're satisfied with your development code, you can integrate it into the main codebase:

1. Test your code thoroughly in the development environment
2. Move the finalized code to the appropriate location in the main codebase
3. Build a new Docker image that includes your changes
4. Deploy the new image to production

## Troubleshooting

- **Files not running**: Ensure the files have been mounted using `mount.sh`
- **TPU not found**: Check that the TPU VM is running and properly initialized
- **Permission errors**: The scripts automatically try with sudo if regular docker commands fail
- **Script errors**: Check logs for detailed error messages
- **Sync not working**: Ensure the TPU VM is running and accessible

## CI/CD Integration

The development environment is designed to be compatible with CI/CD workflows:

- **Automated Testing**: Use the `sync_code.sh` script to quickly update code on the TPU VM
- **Continuous Integration**: Set up automated tests that run after code is synced
- **Rapid Iteration**: Use the watch mode to automatically sync code when changes are detected
- **Persistent Containers**: Keep Docker containers running between code changes
- **Hot Reloading**: Restart containers automatically when code changes

## Performance Considerations

For optimal development performance:

- **Minimize Data Size**: Use small test datasets during development
- **Reduce Model Size**: Use smaller model configurations for faster iteration
- **Cache Preprocessing**: Avoid repeating expensive preprocessing steps
- **Background Container**: Keep a container running in the background for faster execution
- **Profile Early**: Use the TPU profiler to identify bottlenecks early in development 