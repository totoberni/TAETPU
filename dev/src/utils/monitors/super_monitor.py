#!/usr/bin/env python3
"""
Base monitoring class with common functionality for all monitor types.
Provides a unified interface for monitoring capabilities with integrated logging.
"""
import os
import sys
import threading
import time
import json
import socket
from datetime import datetime
import tensorflow as tf

from .monitor_interface import MonitorInterface, MetricsPublisher
from .cloud_monitor import CloudMonitoringClient, CLOUD_MONITORING_AVAILABLE
from ..logging.cls_logging import log, log_success, log_warning, log_error
from ..logging.config_loader import get_config
from ..logging.path_utils import resolve_path, ensure_directory, is_gcs_path

class SuperMonitor(MonitorInterface, MetricsPublisher):
    """Base monitoring class with common functionality for all monitor types."""
    
    def __init__(self, name, log_dir=None, sampling_interval=None, config=None, config_path=None):
        """Initialize base monitor
        
        Args:
            name: Name of the monitor for logging
            log_dir: Directory for storing logs (if None, use config value)
            sampling_interval: Sampling interval in seconds (if None, use config value)
            config: Pre-loaded configuration (if None, load from config_path)
            config_path: Path to configuration file (if None, use default)
        """
        # Initialize MetricsPublisher
        MetricsPublisher.__init__(self)
        
        self.name = name.lower()
        
        # Load configuration (if not provided)
        if config is None:
            self.config = get_config(config_path)
        else:
            self.config = config
        
        # Load monitor-specific configuration
        monitor_config = self.config.get(f"{self.name}_monitor", {})
        
        # Set up logging directory (use specified, or from config, or default)
        if log_dir is None:
            # Use config value if available, otherwise default
            log_dir = monitor_config.get("log_dir", f"logs/{self.name}")
        self.log_dir = log_dir
        ensure_directory(self.log_dir)
        
        # Set up sampling interval (use specified, or from config, or default)
        if sampling_interval is None:
            sampling_interval = monitor_config.get("sampling_interval", 60)
        self.sampling_interval = sampling_interval
        
        # Initialize monitoring thread
        self.monitoring_thread = None
        self.stop_event = threading.Event()
        
        # Initialize TensorBoard writer
        self._setup_tensorboard_writer(monitor_config)
        
        # Initialize Cloud Monitoring
        self._setup_cloud_monitoring()
        
        # Set GCS bucket name from config
        self.bucket_name = self.config.get("bucket_name")
        
        # Check if this monitor is enabled in configuration
        self.enabled = monitor_config.get("enabled", True)
        if not self.enabled:
            log_warning(f"{self.name.upper()} Monitor is disabled in configuration")
        
        log_success(f"Initialized {self.name.upper()} Monitor with sampling interval of {self.sampling_interval}s")
    
    def _setup_tensorboard_writer(self, monitor_config):
        """Set up TensorBoard writer.
        
        Args:
            monitor_config: Monitor-specific configuration
        """
        # Get TensorBoard log directory from config
        tb_log_dir = monitor_config.get("tb_log_dir", self.name)
        tensorboard_base = self.config.get("tensorboard_base", "tensorboard-logs/")
        
        # Determine if we should use GCS
        use_gcs = self.config.get("use_gcs", False)
        bucket_name = self.config.get("bucket_name")
        
        if use_gcs and bucket_name:
            # Use GCS path
            self.tb_log_dir = resolve_path(
                tb_log_dir, 
                use_gcs=True, 
                bucket_name=bucket_name, 
                gcs_base_dir=tensorboard_base
            )
            self.using_gcs = True
            log_success(f"{self.name.upper()} Monitor writing TensorBoard logs to GCS: {self.tb_log_dir}")
        else:
            # Use local path
            self.tb_log_dir = os.path.join("logs/tensorboard", tb_log_dir)
            ensure_directory(self.tb_log_dir)
            self.using_gcs = False
            log_success(f"{self.name.upper()} Monitor writing TensorBoard logs locally: {self.tb_log_dir}")
        
        # Create a TensorBoard writer
        try:
            self.tb_writer = tf.summary.create_file_writer(self.tb_log_dir)
            log_success(f"{self.name.upper()} Monitor TensorBoard writer initialized")
        except Exception as e:
            log_error(f"Failed to initialize TensorBoard writer: {e}")
            self.tb_writer = None
    
    def _setup_cloud_monitoring(self):
        """Set up Google Cloud Monitoring client."""
        # Get project ID from config
        project_id = self.config.get("google_cloud", {}).get("project_id")
        
        # Initialize the Cloud Monitoring client
        self.cloud_monitor = CloudMonitoringClient(project_id)
        
        if self.cloud_monitor.is_available():
            log_success(f"Cloud Monitoring initialized for {self.name.upper()} Monitor")
    
    def set_bucket_name(self, bucket_name):
        """Set GCS bucket name to monitor
        
        Args:
            bucket_name: Name of the GCS bucket
            
        Returns:
            self: Returns self for method chaining
        """
        self.bucket_name = bucket_name
        log(f"Set bucket name to: {bucket_name}")
        return self
    
    def start(self):
        """Start monitoring in a separate thread.
        
        Returns:
            bool: True if monitoring started successfully, False otherwise
        """
        if not self.enabled:
            log_warning(f"{self.name.upper()} Monitor is disabled. Not starting.")
            return False
        
        if self.monitoring_thread and self.monitoring_thread.is_alive():
            log_warning(f"{self.name.upper()} Monitor is already running.")
            return True
        
        # Reset stop event
        self.stop_event.clear()
        
        # Create and start monitoring thread
        self.monitoring_thread = threading.Thread(
            target=self._monitoring_loop,
            name=f"{self.name}-monitor-thread"
        )
        self.monitoring_thread.daemon = True
        
        try:
            self.monitoring_thread.start()
            log_success(f"{self.name.upper()} Monitor started with sampling interval of {self.sampling_interval}s")
            return True
        except Exception as e:
            log_error(f"Failed to start {self.name.upper()} Monitor: {e}")
            return False
    
    def stop(self):
        """Stop monitoring.
        
        Returns:
            bool: True if stopped successfully, False otherwise
        """
        if not self.monitoring_thread or not self.monitoring_thread.is_alive():
            log_warning(f"{self.name.upper()} Monitor is not running.")
            return True
        
        # Signal the monitoring thread to stop
        self.stop_event.set()
        
        try:
            # Wait for monitoring thread to finish (with timeout)
            self.monitoring_thread.join(timeout=5)
            
            if self.monitoring_thread.is_alive():
                log_warning(f"{self.name.upper()} Monitor thread did not terminate gracefully")
                return False
            else:
                log_success(f"{self.name.upper()} Monitor stopped")
                return True
        except Exception as e:
            log_error(f"Error stopping {self.name.upper()} Monitor: {e}")
            return False
    
    def _monitoring_loop(self):
        """Main monitoring loop that runs in a separate thread."""
        log(f"{self.name.upper()} Monitor loop started")
        
        try:
            step = 0
            
            while not self.stop_event.is_set():
                start_time = time.time()
                
                try:
                    # Get current metrics
                    metrics = self.get_metrics()
                    
                    # Record metrics to TensorBoard
                    self.record_metrics(metrics, step)
                    
                    # Publish metrics to subscribers
                    self.publish_metrics(metrics, datetime.now())
                    
                    # Increment step
                    step += 1
                except Exception as e:
                    log_error(f"Error in {self.name.upper()} Monitor loop: {e}")
                
                # Sleep until next sample (accounting for processing time)
                elapsed = time.time() - start_time
                sleep_time = max(0, self.sampling_interval - elapsed)
                
                # Use stop_event.wait() instead of time.sleep() to allow for early termination
                if sleep_time > 0 and not self.stop_event.wait(sleep_time):
                    continue
                else:
                    # Either stop_event was set or no sleep was needed
                    if self.stop_event.is_set():
                        break
        
        except Exception as e:
            log_error(f"Unexpected error in {self.name.upper()} Monitor thread: {e}")
        
        log(f"{self.name.upper()} Monitor loop ended")
    
    def get_metrics(self):
        """Get current metrics.
        
        Returns:
            dict: Dictionary of metrics (empty by default, to be implemented by subclasses)
        """
        # Base implementation returns empty metrics dictionary
        # Subclasses should override this method to provide actual metrics
        return {
            "timestamp": datetime.now().isoformat(),
            "monitor_name": self.name,
        }
    
    def record_metrics(self, metrics=None, step=None):
        """Record metrics to TensorBoard.
        
        Args:
            metrics: Dictionary of metrics to record (if None, collect and record current metrics)
            step: Step/timestamp to associate with metrics
        """
        if metrics is None:
            metrics = self.get_metrics()
        
        if step is None:
            step = int(time.time())
        
        if not self.tb_writer:
            log_warning(f"{self.name.upper()} Monitor TensorBoard writer not available")
            return
        
        try:
            with self.tb_writer.as_default():
                # Record scalar metrics
                for key, value in metrics.items():
                    if key == "timestamp":
                        continue
                    
                    # Only record numeric values
                    if isinstance(value, (int, float)):
                        tf.summary.scalar(key, value, step=step)
            
            # Explicitly flush the writer
            self.tb_writer.flush()
        except Exception as e:
            log_error(f"Error recording metrics to TensorBoard: {e}")
    
    def __enter__(self):
        """Context manager entry.
        
        Returns:
            self: Returns self for use in context manager
        """
        self.start()
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit."""
        self.stop()

    def __del__(self):
        """Destructor to ensure resources are cleaned up."""
        self.stop()

    def check_network_connectivity(self):
        """Check network connectivity to key services
        
        Returns:
            dict: Results of connectivity checks to various services
        """
        services = [
            {"name": "Google Cloud Storage", "host": "storage.googleapis.com", "port": 443},
            {"name": "Google APIs", "host": "www.googleapis.com", "port": 443},
            {"name": "PyPI", "host": "pypi.org", "port": 443},
            {"name": "GitHub", "host": "github.com", "port": 443},
            {"name": "TensorFlow", "host": "tensorflow.org", "port": 443}
        ]
        
        result = {
            "timestamp": datetime.now().isoformat(),
            "services": {},
            "total_services": len(services),
            "available_services": 0
        }
        
        for service in services:
            service_name = service["name"]
            host = service["host"]
            port = service["port"]
            
            service_result = {
                "host": host,
                "port": port
            }
            
            # Test basic connectivity
            start_time = time.time()
            try:
                # Create socket
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.settimeout(2)
                
                # Try to connect
                s.connect((host, port))
                s.close()
                
                latency_ms = round((time.time() - start_time) * 1000, 2)
                service_result["status"] = "available"
                service_result["latency_ms"] = latency_ms
                result["available_services"] += 1
            except Exception as e:
                service_result["status"] = "unavailable"
                service_result["error"] = str(e)
                log_warning(f"Service {service_name} unavailable: {e}")
            
            result["services"][service_name] = service_result
        
        return result
    
    def check_network_stats(self):
        """Get current network statistics
        
        Returns:
            dict: Network statistics including RX/TX bytes and rates
        """
        # Try ifconfig first, fall back to ip if not available
        success, output = run_shell_command("ifconfig", timeout=5)
        if not success:
            success, output = run_shell_command(["ip", "-s", "link"], timeout=5)
        
        stats = {
            "timestamp": datetime.now().isoformat(),
            "raw_output": output if success else "Command failed"
        }
        
        # Try to extract metrics from output
        if success and "eth0" in output:
            # Extract bytes received/transmitted
            for line in output.split('\n'):
                if "RX packets" in line or "rx packets" in line:
                    parts = line.split()
                    for i, part in enumerate(parts):
                        if part.lower() == "bytes":
                            try:
                                stats["rx_bytes"] = int(parts[i+1].replace(':', ''))
                            except (IndexError, ValueError):
                                log_warning("Failed to parse RX bytes from network output")
                
                if "TX packets" in line or "tx packets" in line:
                    parts = line.split()
                    for i, part in enumerate(parts):
                        if part.lower() == "bytes":
                            try:
                                stats["tx_bytes"] = int(parts[i+1].replace(':', ''))
                            except (IndexError, ValueError):
                                log_warning("Failed to parse TX bytes from network output")
        
        # Calculate network rates if we have previous measurements
        current_time = time.time()
        if self.prev_network_stats and self.prev_network_time:
            time_diff = current_time - self.prev_network_time
            
            # Calculate RX rate
            if "rx_bytes" in stats and "rx_bytes" in self.prev_network_stats:
                rx_diff = stats["rx_bytes"] - self.prev_network_stats["rx_bytes"]
                stats["rx_bytes_per_sec"] = rx_diff / time_diff if time_diff > 0 else 0
                stats["rx_mbps"] = stats["rx_bytes_per_sec"] * 8 / (1024 * 1024) if time_diff > 0 else 0
            
            # Calculate TX rate
            if "tx_bytes" in stats and "tx_bytes" in self.prev_network_stats:
                tx_diff = stats["tx_bytes"] - self.prev_network_stats["tx_bytes"]
                stats["tx_bytes_per_sec"] = tx_diff / time_diff if time_diff > 0 else 0
                stats["tx_mbps"] = stats["tx_bytes_per_sec"] * 8 / (1024 * 1024) if time_diff > 0 else 0
        
        # Update previous stats for next calculation
        self.prev_network_stats = stats
        self.prev_network_time = current_time
        
        return stats
    
    def check_gcs_bucket_access(self, bucket_name=None):
        """Check access to GCS bucket
        
        Args:
            bucket_name: Name of the GCS bucket (if None, use instance bucket_name)
            
        Returns:
            dict: Results of bucket access check including status and details
        """
        bucket_name = bucket_name or self.bucket_name
        if not bucket_name:
            log_error("No bucket name provided for GCS bucket access check")
            return {
                "timestamp": datetime.now().isoformat(),
                "status": "error",
                "error": "No bucket name provided"
            }
            
        result = {
            "timestamp": datetime.now().isoformat(),
            "bucket": bucket_name,
            "status": "unknown"
        }
        
        try:
            # Test basic bucket listing
            success, output = run_shell_command(f"gsutil ls -l gs://{bucket_name} | head -n 5", shell=True, timeout=10)
            
            if success:
                result["status"] = "accessible"
                result["listing"] = output.strip()
                
                # Try to get bucket size (this is expensive, only do occasionally)
                if time.time() % 3600 < 60:  # Once per hour
                    try:
                        size_success, size_output = run_shell_command(
                            f"gsutil du -s gs://{bucket_name}", shell=True, timeout=30
                        )
                        if size_success and size_output.strip():
                            # Output is in bytes, convert to GB
                            total_bytes = int(size_output.strip().split()[0])
                            result["size_gb"] = round(total_bytes / (1024**3), 2)
                    except Exception as e:
                        log_warning(f"Error getting bucket size: {e}")
            else:
                result["status"] = "inaccessible"
                result["error"] = output
                log_warning(f"GCS bucket {bucket_name} is inaccessible: {output}")
        except Exception as e:
            result["status"] = "error"
            result["error"] = str(e)
            log_error(f"Error checking GCS bucket access: {e}")
        
        return result
        
    # Optional API integration - only used if API components are available
    def save_metrics_for_api(self):
        """Save metrics directly to GCS for TensorBoard backend"""
        try:
            metrics = self.get_metrics()
            
            # Format for export
            export_data = {
                "timestamp": datetime.now().isoformat(),
                "monitor": self.name,
                "status": "ok",
                "metrics": metrics
            }
            
            # Save locally first
            latest_path = os.path.join(self.log_dir, "latest_metrics.json")
            with open(latest_path, "w") as f:
                json.dump(export_data, f, indent=2)
            
            # If using GCS, also write to the bucket
            if self.using_gcs and self.bucket_name:
                # Determine TensorBoard log path
                tb_dir = self.tb_log_dir.replace(f"gs://{self.bucket_name}/", "")
                gcs_path = f"{tb_dir}/latest_metrics.json"
                
                try:
                    from google.cloud import storage
                    client = storage.Client()
                    bucket = client.bucket(self.bucket_name)
                    blob = bucket.blob(gcs_path)
                    blob.upload_from_string(
                        json.dumps(export_data, indent=2),
                        content_type="application/json"
                    )
                    log_success(f"Metrics saved to GCS at {gcs_path}")
                except Exception as e:
                    log_error(f"Error saving to GCS: {e}")
            
            return True
        except Exception as e:
            log_error(f"Error saving metrics: {e}")
            return False
            
    @property
    def has_tpu(self):
        """Check if TPU is available
        
        Returns:
            bool: True if TPU is available
        """
        try:
            import tensorflow as tf
            tpu_devices = tf.config.list_physical_devices('TPU')
            return len(tpu_devices) > 0
        except:
            return False 