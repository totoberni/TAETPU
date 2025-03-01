"""
Example TPU Development Pipeline with Monitoring Support

This script demonstrates a complete machine learning pipeline on TPU that can be
monitored using the TPU monitoring system. It performs:
1. Creation and upload of mock data to GCS
2. Data loading and preprocessing on TPU
3. Matrix multiplication on TPU (computationally intensive)
4. Results storage back to GCS

This example is compatible with mount.sh, run.sh, and scrap.sh utilities.
"""
import os
import sys
import time
import json
import argparse
import numpy as np
import tensorflow as tf
import random
import traceback
from datetime import datetime
from contextlib import contextmanager

# Add parent directory to path for imports to work properly
parent_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if parent_dir not in sys.path:
    sys.path.insert(0, parent_dir)

# Import using standardized approach
try:
    # First try to import by ensuring utils is in the path
    from utils import ensure_imports
    ensure_imports()
    from utils.logging.cls_logging import log, log_success, log_warning, log_error, run_shell_command
    from utils.logging.config_loader import get_config, get_log_dir, get_tensorboard_dir, resolve_path, ensure_directory
    CONFIG_AVAILABLE = True
except ImportError as e:
    # Define fallback logging functions if utils package not found
    print(f"Could not import logging utilities: {e}. Using fallback functions.")
    CONFIG_AVAILABLE = False
    def log(message): print(f"[INFO] {message}")
    def log_success(message): print(f"[SUCCESS] {message}")
    def log_warning(message): print(f"[WARNING] {message}")
    def log_error(message): print(f"[ERROR] {message}")
    def run_shell_command(cmd, timeout=30, shell=False):
        import subprocess
        try:
            if isinstance(cmd, str) and not shell:
                cmd = cmd.split()
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, shell=shell)
            return result.returncode == 0, result.stdout.strip() if result.returncode == 0 else result.stderr.strip()
        except Exception as e:
            return False, str(e)
    # Simple config loading and path resolution
    def get_config(config_path=None): return {}
    def get_log_dir(): return "logs"
    def get_tensorboard_dir(): return os.environ.get("BUCKET_TENSORBOARD", "tensorboard-logs/")
    def resolve_path(path): return path
    def ensure_directory(directory):
        os.makedirs(directory, exist_ok=True)
        return True

# Default GCS bucket from environment
DEFAULT_BUCKET = os.environ.get("BUCKET_NAME", "my-hello-world-bucket")

# Decorator to measure execution time
def timing_decorator(func):
    def wrapper(*args, **kwargs):
        start_time = time.time()
        result = func(*args, **kwargs)
        end_time = time.time()
        log(f"Function {func.__name__} took {end_time - start_time:.2f} seconds to run")
        return result
    return wrapper

# Context manager for error handling
@contextmanager
def error_handling(operation_name):
    try:
        log(f"Starting {operation_name}...")
        yield
        log_success(f"{operation_name} completed successfully")
    except Exception as e:
        log_error(f"Error during {operation_name}: {str(e)}")
        log_error(traceback.format_exc())
        raise

def load_configuration(config_path=None):
    """
    Load configuration from log_config.yaml or environment variables
    
    Args:
        config_path: Optional path to configuration file
        
    Returns:
        dict: Configuration dictionary with paths resolved
    """
    # Load configuration using the standardized approach
    if CONFIG_AVAILABLE:
        config = get_config(config_path)
        log_success(f"Loaded configuration from {config_path or 'default location'}")
    else:
        # Fallback to a minimal configuration
        config = {
            "base_log_dir": "logs",
            "tensorboard_base": os.environ.get("BUCKET_TENSORBOARD", "tensorboard-logs/"),
            "bucket_name": os.environ.get("BUCKET_NAME", DEFAULT_BUCKET),
            "tpu_monitor": {
                "log_dir": "logs/tpu",
                "tb_log_dir": "tpu"
            },
            "bucket_monitor": {
                "log_dir": "logs/bucket",
                "tb_log_dir": "bucket"
            }
        }
        log_warning("Using fallback configuration due to missing config loader")
    
    return config

def get_directories(config, data_dir=None):
    """
    Get directories for logs, data, and TensorBoard from configuration
    
    Args:
        config: Configuration dictionary
        data_dir: Optional override for data directory
        
    Returns:
        tuple: (log_dir, data_dir, tensorboard_dir)
    """
    # Get log directory from config
    if CONFIG_AVAILABLE:
        log_dir = get_log_dir(config)
    else:
        log_dir = config.get("base_log_dir", "logs")
    
    # Use data_dir from argument or default
    if data_dir is None:
        data_dir = config.get("data_dir", "/tmp/tpu_data")
    
    # Get TensorBoard directory from config
    if CONFIG_AVAILABLE:
        tensorboard_dir = get_tensorboard_dir(config)
    else:
        tensorboard_dir = config.get("tensorboard_base", os.environ.get("BUCKET_TENSORBOARD", "tensorboard-logs/"))
    
    # Ensure directories exist
    ensure_directory(log_dir)
    ensure_directory(data_dir)
    
    # Log the directory configuration
    log(f"Using log directory: {log_dir}")
    log(f"Using data directory: {data_dir}")
    log(f"Using TensorBoard directory: {tensorboard_dir}")
    
    return log_dir, data_dir, tensorboard_dir

class ExampleTPUApp:
    """
    Example TPU application demonstrating typical TPU operations with monitoring support
    """
    def __init__(self, bucket_name=None, matrix_size=1000, data_dir=None, config_path=None):
        """
        Initialize the example app
        
        Args:
            bucket_name: GCS bucket name (if None, will use one from config)
            matrix_size: Size of matrices to generate
            data_dir: Directory for data files
            config_path: Path to configuration file
        """
        # Load configuration
        self.config = load_configuration(config_path)
        
        # Set up paths using configuration
        self.log_dir, self.data_dir, self.tensorboard_dir = get_directories(self.config, data_dir)
        
        # Set up matrix size
        self.matrix_size = matrix_size
        log(f"Matrix size: {matrix_size}x{matrix_size}")
        
        # Set up bucket name - prioritize argument, then config, then environment
        if bucket_name:
            self.bucket_name = bucket_name
        else:
            self.bucket_name = (
                self.config.get("bucket_name") or 
                self.config.get("storage", {}).get("bucket") or
                self.config.get("bucket_monitor", {}).get("bucket_name") or
                os.environ.get("BUCKET_NAME", DEFAULT_BUCKET)
            )
        log(f"Using GCS bucket: {self.bucket_name}")
        
        # Initialize TensorFlow
        self._setup_tensorflow()
    
    def _setup_tensorflow(self):
        """Set up TensorFlow environment"""
        # Check for TPU
        resolver = tf.distribute.cluster_resolver.TPUClusterResolver()
        tf.config.experimental_connect_to_cluster(resolver)
        tf.tpu.experimental.initialize_tpu_system(resolver)
        self.strategy = tf.distribute.TPUStrategy(resolver)
        
        # Log TPU information
        tpu_devices = tf.config.list_logical_devices('TPU')
        log_success(f"Found {len(tpu_devices)} TPU devices: {tpu_devices}")
        
        # Set up logging directory for TensorBoard
        self.tf_log_dir = os.path.join(self.tensorboard_dir, "example")
        ensure_directory(self.tf_log_dir)
        
        # Create summary writer for TensorBoard
        self.summary_writer = tf.summary.create_file_writer(self.tf_log_dir)
    
    @timing_decorator
    def generate_data(self):
        """Generate random matrices for processing"""
        with error_handling("Data Generation"):
            # Calculate size based on matrix dimensions
            size_mb = (self.matrix_size * self.matrix_size * 8) / (1024 * 1024)
            log(f"Generating random matrices (approximately {size_mb:.2f} MB each)")
            
            # Generate matrices
            self.matrix_a = np.random.random((self.matrix_size, self.matrix_size)).astype(np.float32)
            self.matrix_b = np.random.random((self.matrix_size, self.matrix_size)).astype(np.float32)
            
            # Save to local file system
            matrix_a_path = os.path.join(self.data_dir, "matrix_a.npy")
            matrix_b_path = os.path.join(self.data_dir, "matrix_b.npy")
            
            np.save(matrix_a_path, self.matrix_a)
            np.save(matrix_b_path, self.matrix_b)
            
            log_success(f"Matrices saved to {matrix_a_path} and {matrix_b_path}")
            return matrix_a_path, matrix_b_path
    
    @timing_decorator
    def upload_to_gcs(self, local_path, gcs_path):
        """Upload data to GCS"""
        with error_handling("GCS Upload"):
            # Construct the full GCS path
            full_gcs_path = f"gs://{self.bucket_name}/{gcs_path}"
            
            # Use gsutil command to upload
            cmd = f"gsutil cp {local_path} {full_gcs_path}"
            log(f"Uploading to {full_gcs_path}")
            
            success, output = run_shell_command(cmd)
            if success:
                log_success(f"Uploaded {local_path} to {full_gcs_path}")
                return full_gcs_path
            else:
                log_error(f"Upload failed: {output}")
                return None
    
    @timing_decorator
    def load_from_gcs(self, gcs_path, local_path):
        """Download data from GCS"""
        with error_handling("GCS Download"):
            # Construct the full GCS path
            full_gcs_path = f"gs://{self.bucket_name}/{gcs_path}"
            
            # Use gsutil command to download
            cmd = f"gsutil cp {full_gcs_path} {local_path}"
            log(f"Downloading from {full_gcs_path}")
            
            success, output = run_shell_command(cmd)
            if success:
                log_success(f"Downloaded {full_gcs_path} to {local_path}")
                return local_path
            else:
                log_error(f"Download failed: {output}")
                return None
    
    @timing_decorator
    def process_on_tpu(self):
        """Process data on TPU"""
        with error_handling("TPU Processing"):
            # Convert to TensorFlow tensors
            tf_a = tf.convert_to_tensor(self.matrix_a)
            tf_b = tf.convert_to_tensor(self.matrix_b)
            
            # Perform matrix multiplication on TPU
            with self.strategy.scope():
                log(f"Performing matrix multiplication on TPU...")
                
                # Define computation
                @tf.function
                def matmul_fn(a, b):
                    return tf.matmul(a, b)
                
                # Record start time for performance measurement
                start_time = time.time()
                
                # Execute on TPU
                result = self.strategy.run(matmul_fn, args=(tf_a, tf_b))
                
                # Wait for completion and record time
                result = result.numpy()
                end_time = time.time()
                
                # Log performance metrics
                duration = end_time - start_time
                operations = 2 * (self.matrix_size ** 3)  # Approximate FLOPs for matrix multiplication
                flops = operations / duration
                gflops = flops / 1e9
                
                log_success(f"Matrix multiplication completed in {duration:.4f} seconds")
                log(f"Performance: {gflops:.2f} GFLOPS")
                
                # Log to TensorBoard
                with self.summary_writer.as_default():
                    tf.summary.scalar('performance/gflops', gflops, step=0)
                    tf.summary.scalar('timing/matmul_seconds', duration, step=0)
                
                # Save result
                result_path = os.path.join(self.data_dir, "result.npy")
                np.save(result_path, result)
                
                return result_path, gflops
    
    def run_pipeline(self):
        """Run the complete example pipeline"""
        log("Starting Example TPU Pipeline")
        
        # Stage 1: Generate data
        matrix_a_path, matrix_b_path = self.generate_data()
        
        # Stage 2: Upload matrices to GCS
        gcs_a_path = self.upload_to_gcs(matrix_a_path, "data/matrix_a.npy")
        gcs_b_path = self.upload_to_gcs(matrix_b_path, "data/matrix_b.npy")
        
        # Stage 3: Process on TPU
        result_path, gflops = self.process_on_tpu()
        
        # Stage 4: Upload result to GCS
        gcs_result_path = self.upload_to_gcs(result_path, "results/result.npy")
        
        # Create summary report
        report = {
            "timestamp": datetime.now().isoformat(),
            "matrix_size": self.matrix_size,
            "performance_gflops": gflops,
            "input_files": [gcs_a_path, gcs_b_path],
            "output_file": gcs_result_path,
            "tensorboard_dir": self.tf_log_dir
        }
        
        # Save report to file
        report_path = os.path.join(self.log_dir, "example_report.json")
        with open(report_path, 'w') as f:
            json.dump(report, f, indent=2)
        
        log_success(f"Pipeline completed successfully. Report saved to {report_path}")
        return report

def parse_args():
    """Parse command line arguments"""
    parser = argparse.ArgumentParser(description="Example TPU Pipeline with Monitoring Support")
    parser.add_argument("--bucket", help="GCS bucket name")
    parser.add_argument("--matrix-size", type=int, default=1000, help="Size of matrices")
    parser.add_argument("--data-dir", default="/tmp/tpu_data", help="Directory for data storage")
    parser.add_argument("--config", help="Path to configuration file")
    return parser.parse_args()

def main():
    """Main entry point"""
    # Parse command line arguments
    args = parse_args()
    
    # Create and run the example app
    app = ExampleTPUApp(
        bucket_name=args.bucket,
        matrix_size=args.matrix_size,
        data_dir=args.data_dir,
        config_path=args.config
    )
    
    # Run the pipeline
    app.run_pipeline()

if __name__ == "__main__":
    main() 