"""
Bucket monitoring for GCS bucket and TPU VM data transfers.
Provides utilities to measure data transfer rates and monitor network statistics.
"""
import os
import json
import time
import threading
from datetime import datetime
import tensorflow as tf
from ..logging.cls_logging import (
    log, log_success, log_warning, log_error, 
    run_shell_command, ensure_directory
)
from ..logging.config_loader import get_config
from .super_monitor import SuperMonitor

# Try to import Google Cloud Monitoring
try:
    from google.cloud import monitoring_v3
    CLOUD_MONITORING_AVAILABLE = True
except ImportError:
    CLOUD_MONITORING_AVAILABLE = False
    log_warning("Google Cloud Monitoring libraries not available; falling back to local metrics.")

class BucketMonitor(SuperMonitor):
    """Monitor data transfer between GCS bucket and TPU VM using Cloud Monitoring and TensorBoard."""

    def __init__(self, bucket_name=None, log_dir=None, sampling_interval=None, config=None, config_path=None):
        """
        Initialize bucket monitor.
        
        Args:
            bucket_name: GCS bucket name to monitor (if None, use config)
            log_dir: Directory for logs (if None, use config)
            sampling_interval: Interval in seconds between samples (if None, use config)
            config: Pre-loaded configuration (if None, load from config_path)
            config_path: Path to configuration file (if None, use default)
        """
        # Initialize base monitor
        super().__init__(name="bucket", log_dir=log_dir, sampling_interval=sampling_interval, config=config, config_path=config_path)
        
        # Set bucket name from parameter, config, or env
        if bucket_name is None:
            bucket_name = self.config.get("bucket_name")
        
        if bucket_name:
            self.set_bucket_name(bucket_name)
        elif not self.bucket_name:
            log_error("Bucket name is missing. BucketMonitor cannot proceed without a bucket.")
        
        # Get additional configuration parameters from bucket_config
        bucket_config = self.config.get("bucket_monitor", {})
        self.params = bucket_config.get("params", {})
        self.file_size_mb = self.params.get("file_size_mb", 10)
        self.interval_minutes = self.params.get("interval_minutes", 30)
        self.test_dir = bucket_config.get("test_dir")
        
        # Initialize states for transfer tests
        self.transfer_thread = None
        self.stop_transfer_test = False
        self.last_transfer_results = None
        
        # Get TensorBoard log directory from config
        tb_log_dir = bucket_config.get("tb_log_dir", "bucket")
        tensorboard_base = self.config.get("tensorboard_base", "tensorboard-logs/")
        self.tb_log_dir = os.path.join("logs/tensorboard", tb_log_dir)
        
        # Initialize Cloud Monitoring if available
        if CLOUD_MONITORING_AVAILABLE:
            try:
                self.monitoring_client = monitoring_v3.MetricServiceClient()
                # Get project ID from config or environment
                project_id = self.config.get("google_cloud", {}).get("project_id")
                self.project_name = f"projects/{project_id}" if project_id else None
                log_success("Google Cloud Monitoring client initialized in BucketMonitor.")
            except Exception as e:
                log_warning(f"Failed to initialize Cloud Monitoring client: {e}")
                self.monitoring_client = None
                self.project_name = None
        else:
            self.monitoring_client = None
            self.project_name = None
            
        # Create a TensorBoard writer for internal use (independent of dashboard)
        ensure_directory(self.tb_log_dir)
        
        # Determine TensorBoard path for GCS if use_gcs is enabled
        use_gcs = self.config.get("use_gcs", False)
        if use_gcs and self.bucket_name:
            # Create the full TensorBoard path for GCS
            tb_gcs_dir = f"gs://{self.bucket_name}/{tensorboard_base}/{tb_log_dir}"
            self.tb_writer = tf.summary.create_file_writer(tb_gcs_dir)
            log_success(f"BucketMonitor writing TensorBoard logs to GCS: {tb_gcs_dir}")
        else:
            # Use local path
            self.tb_writer = tf.summary.create_file_writer(self.tb_log_dir)
            log_success(f"BucketMonitor writing TensorBoard logs locally: {self.tb_log_dir}")
        
        log_success(f"BucketMonitor initialized (file_size={self.file_size_mb}MB, interval={self.interval_minutes}min)")
    
    def time_gcs_operation(self, operation="download", file_path=None, size_mb=None, cleanup=True, profile=False):
        """Time a GCS bucket operation (upload/download)"""
        if not self.bucket_name:
            log_error("No bucket name provided")
            return {"status": "error", "error": "No bucket name provided"}
            
        # Use parameter size if provided, otherwise use config
        size_mb = size_mb or self.file_size_mb
        
        # Get test directory - use either the config from log_config.yaml or determine dynamically
        if self.test_dir:
            test_dir = self.test_dir
        else:
            # Try to use the BUCKET_DATRAIN path from config
            bucket_datrain = self.config.get("bucket_datrain")
            if bucket_datrain:
                test_dir = f"{bucket_datrain}test/"
            else:
                # Default path if no config available
                test_dir = f"gs://{self.bucket_name}/test/"
            
        result = {
            "timestamp": datetime.now().isoformat(),
            "operation": operation,
            "bucket": self.bucket_name
        }
        
        try:
            # Create test file for upload if needed
            if operation == "upload" and file_path is None:
                temp_dir = "/tmp/gcs_test"
                ensure_directory(temp_dir)
                temp_file = f"{temp_dir}/test_file_{size_mb}mb_{int(time.time())}.bin"
                
                # Create file with random data
                log(f"Creating test file of {size_mb}MB for upload...")
                try:
                    success, output = run_shell_command(
                        f"dd if=/dev/urandom of={temp_file} bs=1M count={size_mb}",
                        shell=True,
                        timeout=30
                    )
                    
                    if not success:
                        log_error(f"Failed to create test file: {output}")
                        return {"status": "error", "error": f"Failed to create test file: {output}"}
                except Exception as e:
                    log_error(f"Exception when creating test file: {e}")
                    return {"status": "error", "error": f"Exception creating test file: {e}"}
                    
                file_path = temp_file
                result["file_size_mb"] = size_mb
                result["file_path"] = file_path
            elif file_path:
                # Get file size if path is provided
                if os.path.exists(file_path):
                    file_size = os.path.getsize(file_path)
                    result["file_size_bytes"] = file_size
                    result["file_size_mb"] = round(file_size / (1024 * 1024), 2)
                else:
                    log_error(f"File path does not exist: {file_path}")
                    return {"status": "error", "error": f"File does not exist: {file_path}"}
            
            # Define GCS path
            file_name = os.path.basename(file_path) if file_path else f"test_file_{int(time.time())}.bin"
            gcs_path = f"{test_dir}{file_name}"
            result["gcs_path"] = gcs_path
            
            # Execute operation and time it
            start_time = time.time()
            
            if operation == "upload" and file_path:
                log(f"Uploading file to {gcs_path}...")
                try:
                    success, output = run_shell_command(["gsutil", "cp", file_path, gcs_path], timeout=300)
                    if not success:
                        log_error(f"Upload failed: {output}")
                except Exception as e:
                    log_error(f"Upload exception: {e}")
                    success, output = False, str(e)
            elif operation == "download":
                # Define download path
                download_path = file_path if file_path else f"/tmp/gcs_test/downloaded_{file_name}"
                ensure_directory(os.path.dirname(download_path))
                result["download_path"] = download_path
                
                log(f"Downloading file from {gcs_path}...")
                try:
                    success, output = run_shell_command(["gsutil", "cp", gcs_path, download_path], timeout=300)
                    if not success:
                        log_error(f"Download failed: {output}")
                except Exception as e:
                    log_error(f"Download exception: {e}")
                    success, output = False, str(e)
            else:
                log_error(f"Invalid operation: {operation}")
                return {"status": "error", "error": f"Invalid operation: {operation}"}
            
            end_time = time.time()
            duration = end_time - start_time
            
            result["duration_seconds"] = duration
            result["status"] = "success" if success else "error"
            
            if not success:
                result["error"] = output
                log_error(f"Operation failed: {output}")
                return result
            
            # Calculate transfer rate
            if "file_size_mb" in result:
                result["transfer_rate_mbps"] = result["file_size_mb"] / duration
                log_success(f"{operation.capitalize()} rate: {result['transfer_rate_mbps']:.2f} MB/s")
            
            # Clean up if requested
            if cleanup:
                cleanup_tasks = []
                
                if operation == "upload" and file_path.startswith("/tmp/gcs_test"):
                    try:
                        os.remove(file_path)
                        cleanup_tasks.append(f"Removed temporary upload file: {file_path}")
                    except Exception as e:
                        log_warning(f"Failed to remove upload file: {e}")
                
                if operation == "download" and "download_path" in result:
                    try:
                        os.remove(result["download_path"])
                        cleanup_tasks.append(f"Removed downloaded file: {result['download_path']}")
                    except Exception as e:
                        log_warning(f"Failed to remove download file: {e}")
                
                # Clean up GCS test file
                try:
                    success, _ = run_shell_command(["gsutil", "rm", gcs_path], timeout=60)
                    if success:
                        cleanup_tasks.append(f"Removed GCS test file: {gcs_path}")
                    else:
                        log_warning(f"Failed to remove GCS test file: {gcs_path}")
                except Exception as e:
                    log_warning(f"Failed to remove GCS test file {gcs_path}: {e}")
                
                result["cleanup"] = cleanup_tasks
            
            # Store the result for future reference
            self.last_transfer_results = result
            
            # Log to TensorBoard if profiling is requested
            if profile and "transfer_rate_mbps" in result:
                try:
                    with self.tb_writer.as_default():
                        tf.summary.scalar(f"gcs_{operation}_rate_mbps", result["transfer_rate_mbps"], step=int(time.time()))
                        self.tb_writer.flush()
                except Exception as e:
                    log_error(f"Failed to log transfer rate to TensorBoard: {e}")
                
        except Exception as e:
            log_error(f"Error during {operation} test: {e}")
            result["status"] = "error"
            result["error"] = str(e)
        
        return result
    
    def collect_info(self):
        """Collect network statistics and transfer info (implements base method)"""
        # Use base class implementation for network statistics
        network_stats = super().check_network_stats()
        
        # Add some calculated metrics if available
        info = {
            "timestamp": datetime.now().isoformat(),
            "network": network_stats
        }
        
        # Add last known transfer metrics if available
        if hasattr(self, 'last_transfer_results') and self.last_transfer_results:
            info["transfer"] = self.last_transfer_results
        
        # Check bucket access using base class implementation
        if self.bucket_name:
            info["bucket_access"] = super().check_gcs_bucket_access(self.bucket_name)
        
        return info
    
    def _add_standard_metrics(self, standard_metrics, info):
        """Add GCS transfer metrics to standard format (implements base method)"""
        # Set overall status
        standard_metrics["status"] = "ok"
        
        # Add metadata
        standard_metrics["metadata"]["bucket_name"] = self.bucket_name
        
        # Add metrics
        metrics = standard_metrics["metrics"]
        
        # Network metrics
        if "network" in info and "rx_bytes" in info["network"]:
            metrics["network_rx_bytes"] = info["network"]["rx_bytes"]
            metrics["network_rx_mb"] = round(info["network"]["rx_bytes"] / (1024 * 1024), 2)
        
        if "network" in info and "tx_bytes" in info["network"]:
            metrics["network_tx_bytes"] = info["network"]["tx_bytes"]
            metrics["network_tx_mb"] = round(info["network"]["tx_bytes"] / (1024 * 1024), 2)
        
        # Add network rates if available
        if "network" in info:
            if "rx_mbps" in info["network"]:
                metrics["network_rx_mbps"] = info["network"]["rx_mbps"]
            if "tx_mbps" in info["network"]:
                metrics["network_tx_mbps"] = info["network"]["tx_mbps"]
        
        # Add transfer metrics if available
        if "transfer" in info:
            transfer = info["transfer"]
            if "operation" in transfer and "transfer_rate_mbps" in transfer:
                metrics[f"gcs_{transfer['operation']}_rate_mbps"] = transfer["transfer_rate_mbps"]
                metrics[f"gcs_{transfer['operation']}_duration_seconds"] = transfer.get("duration_seconds", 0)
                
        # Log to TensorBoard directly
        try:
            with self.tb_writer.as_default():
                for key, value in metrics.items():
                    if isinstance(value, (int, float)):
                        tf.summary.scalar(key, value, step=int(time.time()))
                self.tb_writer.flush()
        except Exception as e:
            log_warning(f"Failed to log metrics to TensorBoard: {e}")
        
    def log_current_info(self, info):
        """Log current GCS transfer metrics (implements base method)"""
        metrics = info.get("metrics", {})
        
        if "network_rx_mb" in metrics and "network_tx_mb" in metrics:
            rx_mb = metrics["network_rx_mb"]
            tx_mb = metrics["network_tx_mb"]
            log(f"Network stats: RX: {rx_mb:.2f} MB, TX: {tx_mb:.2f} MB")
            
        if "network_rx_mbps" in metrics and "network_tx_mbps" in metrics:
            rx_mbps = metrics["network_rx_mbps"]
            tx_mbps = metrics["network_tx_mbps"]
            log(f"Network rates: RX: {rx_mbps:.2f} Mbps, TX: {tx_mbps:.2f} Mbps")
            
        for key, value in metrics.items():
            if key.startswith("gcs_") and key.endswith("_rate_mbps"):
                operation = key.replace("gcs_", "").replace("_rate_mbps", "")
                log(f"GCS {operation} rate: {value:.2f} MB/s")
    
    def monitor_gcs_transfer_rate(self, interval_minutes=30, file_size_mb=10):
        """Start periodic monitoring of GCS transfer rates."""
        if self.transfer_thread and self.transfer_thread.is_alive():
            log_warning("Transfer monitoring thread already running")
            return False
        
        self.stop_transfer_test = False

        def _monitoring_worker():
            log_success(f"Started GCS transfer monitoring (interval: {interval_minutes} minutes)")
            results = []
            while not self.stop_transfer_test:
                try:
                    time.sleep(interval_minutes * 60)
                    if self.stop_transfer_test:
                        break
                        
                    log("Running GCS upload speed test...")
                    try:
                        upload_result = self.time_gcs_operation(
                            operation="upload",
                            size_mb=file_size_mb,
                            cleanup=True,
                            profile=True
                        )
                        results.append(upload_result)
                    except Exception as e:
                        log_error(f"Upload test failed: {e}")
                    
                    time.sleep(5)
                    if self.stop_transfer_test:
                        break
                        
                    log("Running GCS download speed test...")
                    try:
                        download_result = self.time_gcs_operation(
                            operation="download",
                            size_mb=file_size_mb,
                            cleanup=True,
                            profile=True
                        )
                        results.append(download_result)
                    except Exception as e:
                        log_error(f"Download test failed: {e}")
                        
                    if len(results) >= 10:
                        self._save_transfer_results(results)
                        results = []
                except Exception as e:
                    log_error(f"Error in transfer monitoring thread: {e}")
                    time.sleep(60)  # Wait a minute before trying again
            if results:
                self._save_transfer_results(results)
            log("GCS transfer monitoring stopped")
        
        self.transfer_thread = threading.Thread(target=_monitoring_worker, daemon=True)
        self.transfer_thread.start()
        
        # Start base monitoring too (for network stats)
        return super().start_monitoring()

    def stop_monitoring_thread(self):
        """Stop all monitoring (overrides base method)"""
        result = super().stop_monitoring_thread()
        if self.transfer_thread and self.transfer_thread.is_alive():
            log("Stopping GCS transfer monitoring...")
            self.stop_transfer_test = True
            self.transfer_thread.join(timeout=10)
            if self.transfer_thread.is_alive():
                log_warning("Transfer monitoring thread did not terminate gracefully")
                return False
        return result
        
    def _save_transfer_results(self, results):
        """Save transfer test results to file"""
        if not results:
            return
        
        try:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            results_path = os.path.join(self.log_dir, f"gcs_transfer_{timestamp}.json")
            
            with open(results_path, "w") as f:
                json.dump(results, f, indent=2)
            
            log_success(f"Saved {len(results)} transfer test results to {results_path}")
        except Exception as e:
            log_error(f"Failed to save transfer results: {e}")
    
    def run_single_transfer_test(self, operation="both", file_size_mb=10):
        """Run a single transfer test and return results"""
        log(f"Running GCS transfer test ({operation})...")
        results = []
        
        try:
            if operation in ["both", "upload"]:
                upload_result = self.time_gcs_operation(
                    operation="upload",
                    size_mb=file_size_mb,
                    cleanup=(operation == "both"),  # Don't clean up if we need the file for download
                    profile=True
                )
                results.append(upload_result)
                
                # If upload failed and we need to do download, we can't proceed
                if upload_result["status"] != "success" and operation == "both":
                    log_error("Upload test failed, cannot proceed with download test")
                    return results
            
            if operation in ["both", "download"]:
                download_result = self.time_gcs_operation(
                    operation="download",
                    cleanup=True,
                    profile=True
                )
                results.append(download_result)
        except Exception as e:
            log_error(f"Transfer test failed: {e}")
        
        return results
    
    def __enter__(self):
        """Context manager entry for 'with' statement (overrides base method)"""
        self.monitor_gcs_transfer_rate()
        return self