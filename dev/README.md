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
    - `example.py`: Basic example demonstrating TPU operations
    - `example_monitoring.py`: Example demonstrating monitoring capabilities
    - `utils/`: Utilities for monitoring and profiling
      - `experiment.py`: Experiment tracking utilities
      - `profiling.py`: TPU profiling utilities
      - `tpu_logging.py`: TPU-specific logging utilities
      - `visualization.py`: Data visualization utilities
  - `mgt/`: Contains management scripts for the development environment
    - `mount.sh`: Script to mount files to the TPU VM
    - `scrap.sh`: Script to remove files from the TPU VM
    - `run.sh`: Script to execute mounted files on the TPU VM
    - `mount_run_scrap.sh`: All-in-one script to mount, run, and optionally clean up files
    - `synch.sh`: Enhanced script for syncing and watching code changes (CI/CD integration)
    - `monitor_tpu.sh`: TPU monitoring script (self-contained)

## Enhanced Monitoring and Logging Utilities

The development environment integrates with advanced monitoring and logging utilities:

### Available Utilities

1. **TPU Logging**
   - `setup_logger`: Configures enhanced logging with console/file outputs
   - `TPUMetricsLogger`: Collects and logs TPU performance metrics
   - `create_progress_bar`: Creates a rich progress bar for training

2. **Profiling**
   - `ModelProfiler`: Profiles memory usage and operation timing
   - `profile_function`: Decorator for profiling individual functions

3. **Experiment Tracking**
   - `ExperimentTracker`: Tracks experiments with TensorBoard and W&B

4. **Visualization Dashboard**
   - `MonitoringDashboard`: Generates reports with interactive visualizations

### Example Usage

The `example_monitoring.py` file demonstrates how to use these utilities:

```python
# Import utilities
from utils.tpu_logging import setup_logger, TPUMetricsLogger
from utils.profiling import ModelProfiler, profile_function
from utils.experiment import ExperimentTracker

# Set up logger with file output
logger = setup_logger(log_level="INFO", log_file="logs/experiment.log")

# Track experiment metrics
experiment = ExperimentTracker(
    experiment_name="my_experiment",
    use_tensorboard=True
)

# Profile model operations
profiler = ModelProfiler(model)
profiler.profile_memory("Before training")

# Track TPU metrics
tpu_logger = TPUMetricsLogger()
tpu_logger.log_metrics(step=current_step)
```

## Running and Debugging Volume-Mounted Code

### Recent Improvements

All management scripts in the `dev/mgt` directory have been improved to:

1. **Work from any directory**: You can call these scripts from any location in the project
2. **Include self-contained logging**: Each script has its own logging functions
3. **Provide better error handling**: Clear error messages and intelligent recovery
4. **Improve pathfinding**: Automatically resolves paths relative to script location
5. **Reuse Docker containers**: Optimizes performance by avoiding container restart

### Using Management Scripts

#### Mounting Files to TPU VM

The `mount.sh` script copies Python files from your local development environment to the TPU VM, making them available for execution.

```bash
# Mount a specific file to the TPU VM (can be run from any directory)
./dev/mgt/mount.sh example_monitoring.py

# Mount multiple files to the TPU VM
./dev/mgt/mount.sh model.py train.py utils.py

# Mount the utils directory (needed for importing utility modules)
./dev/mgt/mount.sh --utils
```

The mounted files are stored in `/tmp/dev/src/` on the TPU VM, and the script validates that the transfer was successful.

#### Running Files on TPU VM

The `run.sh` script executes mounted Python files inside a Docker container on the TPU VM, with TPU acceleration enabled.

```bash
# Run a mounted file on the TPU VM (can be run from any directory)
./dev/mgt/run.sh example_monitoring.py

# Run multiple files sequentially
./dev/mgt/run.sh preprocess.py train.py

# Run a file with arguments
./dev/mgt/run.sh model.py --epochs 10 --batch_size 32
```

This script will:
- Check if each file is mounted and mount it if not found
- Automatically mount the utils directory if needed
- Try running with regular Docker permissions first, then fall back to sudo if needed
- Display logs in real-time with color formatting

#### Removing Files from TPU VM

The `scrap.sh` script cleans up files from the TPU VM when you're done with them.

```bash
# Remove a specific file from the TPU VM (can be run from any directory)
./dev/mgt/scrap.sh example_monitoring.py

# Remove multiple files from the TPU VM
./dev/mgt/scrap.sh model.py train.py

# Remove all files from the TPU VM
./dev/mgt/scrap.sh --all
```

#### All-in-One Workflow (Mount, Run, Clean)

The `mount_run_scrap.sh` script provides a convenient workflow that combines all three operations.

```bash
# Mount, run, and keep example_monitoring.py (can be run from any directory)
./dev/mgt/mount_run_scrap.sh example_monitoring.py

# Mount, run, and clean up model.py
./dev/mgt/mount_run_scrap.sh model.py --clean

# Process multiple files sequentially
./dev/mgt/mount_run_scrap.sh preprocess.py train.py

# Pass arguments to the Python script
./dev/mgt/mount_run_scrap.sh train.py --epochs 10
```

#### Continuous Code Synchronization (CI/CD)

The `synch.sh` script enables a more automated development workflow with file watching and Docker Compose integration.

```bash
# Sync all files in dev/src to TPU VM (can be run from any directory)
./dev/mgt/synch.sh

# Sync all files and restart the container
./dev/mgt/synch.sh --restart

# Watch for changes and sync automatically
./dev/mgt/synch.sh --watch

# Watch for changes and restart container after each sync
./dev/mgt/synch.sh --watch --restart

# Use Docker Compose watch feature for continuous development
./dev/mgt/synch.sh --compose-watch

# Sync only specific files
./dev/mgt/synch.sh --specific model.py data_loader.py

# Include utils directory
./dev/mgt/synch.sh --utils
```

This script provides:
- Continuous development with automated file synchronization
- Support for Docker Compose watch feature (v2.22.0+)
- Multiple file watchers (inotifywait, fswatch) for cross-platform support
- Proper logging using common.sh functions for consistency
- Detailed error handling and recovery mechanisms
- The ability to watch specific files or the entire directory

This is especially useful for:
- Continuous development sessions
- Testing small changes quickly
- Setting up a development pipeline

## CI/CD Integration

The `dev` folder provides CI/CD capabilities for rapid development and iteration:

### Development vs Production Environments

**Important**: The `dev` folder and its contents are designed for development only and **will not be visible after deployment**. The deployment process:

1. Builds a Docker image with production code only
2. Pushes this image to a container registry
3. Deploys the container to production TPU VMs

During development, the workflow is:
1. Make code changes locally
2. Use `synch.sh` to synchronize code to the TPU VM
3. Test changes immediately without rebuilding containers
4. When satisfied, integrate changes into the main codebase

### CI/CD Workflow Integration

The development tools support CI/CD workflows:

1. **Local Development**: Use `synch.sh --watch` during active development to automatically sync changes
2. **Pre-Commit Testing**: Use `mount_run_scrap.sh` to quickly test changes before committing
3. **CI Pipeline Integration**: CI systems can use these scripts to verify code on TPUs before merging
4. **CD Deployment**: Separate deployment scripts build production images without the `dev` directory

### Monitoring During Deployment

The monitoring and profiling utilities from the `utils` directory can be used during both development and production:

```python
# Monitoring code that works in both environments
from utils.experiment import ExperimentTracker

# Track experiments in both dev and production
tracker = ExperimentTracker(
    experiment_name="model_training",
    use_tensorboard=True,
    production_mode=is_production
)
```

## Debugging Techniques

### 1. Real-time TPU Monitoring

The `monitor_tpu.sh` script provides real-time TPU performance monitoring:

```bash
# Start monitoring a specific TPU (can be run from any directory)
./dev/mgt/monitor_tpu.sh start YOUR_TPU_NAME

# Monitor TPU and a specific Python process
./dev/mgt/monitor_tpu.sh start YOUR_TPU_NAME PYTHON_PID

# Stop all monitoring
./dev/mgt/monitor_tpu.sh stop
```

The script:
- Tracks TPU state and health
- Collects utilization metrics
- Generates flame graphs for Python processes
- Saves all data to the `logs/` directory

### 2. Debug Logging

Use the logging utilities from `utils.tpu_logging` to add detailed logging to your code:

```python
from utils.tpu_logging import setup_logger

# Create a logger with different levels for console and file output
logger = setup_logger(
    name="my_debug_logger",
    log_level="DEBUG",  # Console log level
    log_file="logs/debug.log",
    file_log_level="TRACE"  # File log level (even more detailed)
)

# Use it throughout your code
logger.debug("Detailed debug information")
logger.info("Regular progress information")
logger.warning("Warning message")
logger.error("Error message")
```

### 3. TPU Profiling

The framework includes tools to profile TPU execution:

```python
from utils.profiling import ModelProfiler, profile_function

# Profile an entire model
profiler = ModelProfiler(model)
profiler.profile_memory("Before training")
profiler.profile_execution_time(batch_data)

# Profile a specific function
@profile_function
def my_expensive_function(data):
    # Function implementation
    return result
```

### 4. Step-by-Step Debugging Workflow

For debugging complex TPU issues:

1. **Start with small examples**: Use `example.py` as a template
2. **Add debug logging**: Use the logger utilities
3. **Monitor TPU state**: Run `monitor_tpu.sh` to track resource usage
4. **Check TPU availability**: Verify device accessibility
5. **Test incrementally**: Test small parts before running full code
6. **Profile performance**: Use profiling tools to identify bottlenecks
7. **Enable verbose XLA output**: Set `TPU_DEBUG=true` in `.env`

## Example Debugging Workflow

### Debugging a Model Training Issue

1. Create a debugging version of your model in `dev/src/debug_model.py`
2. Add detailed logging at critical points:
   ```python
   logger.debug(f"Input shape: {input_tensor.shape}")
   logger.debug(f"Device: {input_tensor.device}")
   ```
3. Start TPU monitoring:
   ```bash
   ./dev/mgt/monitor_tpu.sh start YOUR_TPU_NAME
   ```
4. Run the code with debug output:
   ```bash
   ./dev/mgt/mount_run_scrap.sh debug_model.py
   ```
5. Examine logs for errors or unexpected values
6. Add profiling to identify performance bottlenecks
7. Make changes and quickly rerun without rebuilding:
   ```bash
   ./dev/mgt/mount_run_scrap.sh debug_model.py
   ```

### Debugging Docker Volume Mounts

If you're experiencing issues with volume mounts:

1. Verify the directories exist on the TPU VM:
   ```bash
   ./dev/mgt/run.sh --command="ls -la /tmp/dev/src"
   ```
2. Check Docker permissions:
   ```bash
   ./dev/mgt/run.sh --command="docker info"
   ```
3. Test a simple mount:
   ```bash
   ./dev/mgt/mount_run_scrap.sh example.py --clean
   ```
4. Use `synch.sh --watch` for more reliable file synchronization

## Creating Custom Scripts

You can create additional scripts in the `dev/src/` directory as needed for your development workflow. These might include:

- Model architecture definitions
- Training scripts
- Evaluation scripts
- Data processing utilities
- Ablation study scripts

All scripts in `dev/src/` can be mounted and run on the TPU VM without rebuilding the Docker image.

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
- **TPU Metrics errors**: Verify that torch_xla is installed and a TPU device is detected
- **Path-related issues**: Scripts now use absolute paths, so this should be rare

## Performance Considerations

For optimal development performance:

- **Minimize Data Size**: Use small test datasets during development
- **Reduce Model Size**: Use smaller model configurations for faster iteration
- **Cache Preprocessing**: Avoid repeating expensive preprocessing steps
- **Background Container**: Keep a container running in the background for faster execution
- **Profile Early**: Use the TPU profiler to identify bottlenecks early in development
- **Monitor Memory**: Use the memory profiler to catch memory leaks before they become an issue 