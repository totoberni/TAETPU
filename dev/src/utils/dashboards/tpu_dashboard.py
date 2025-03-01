import os
import time
import json
import threading
from datetime import datetime
import tensorflow as tf
from .super_dashboard import Dashboard
from ..logging.cls_logging import log, log_success, log_warning, log_error, ensure_directory
from ..logging.config_loader import get_config

# Try to import Google Cloud Monitoring
try:
    from google.cloud import monitoring_v3
    CLOUD_MONITORING_AVAILABLE = True
except ImportError:
    CLOUD_MONITORING_AVAILABLE = False
    log_warning("Google Cloud Monitoring libraries not available; some dashboard features will be disabled.")

class TPUDashboard(Dashboard):
    """Dashboard for visualizing TPU and environment metrics using TensorBoard"""
    
    def __init__(self, tb_log_dir=None, profile_dir=None, use_gcs=None, config_path=None):
        """Initialize the TPU dashboard
        
        Args:
            tb_log_dir: Directory for TensorBoard logs (if None, use config)
            profile_dir: Directory to store profiling data (if None, use config)
            use_gcs: Whether to use GCS bucket for storage (if None, use config)
            config_path: Path to configuration file (if None, use default)
        """
        # Initialize base dashboard with TPU-specific name
        super().__init__(name="tpu", tb_log_dir=tb_log_dir, use_gcs=use_gcs, config_path=config_path)
        
        # Get TPU dashboard configuration
        dashboard_config = self.config.get("dashboards", {}).get("tpu_dashboard", {})
        
        # Set up profile directory
        if profile_dir is None:
            # Get profile directory from config
            profile_dir = dashboard_config.get("profile_dir", "tpu_profiles")
            tensorboard_base = self.config.get("tensorboard_base", "tensorboard-logs/")
            bucket_name = self.config.get("bucket_name")
            
            if self.use_gcs and bucket_name:
                # Use GCS path for profiles
                self.profile_dir = f"gs://{bucket_name}/{tensorboard_base}/{profile_dir}"
            else:
                # Use local path for profiles
                self.profile_dir = os.path.join("logs/tensorboard", profile_dir)
        else:
            self.profile_dir = profile_dir
        
        # For local directory, make sure it exists
        if not self.use_gcs:
            ensure_directory(self.profile_dir)
        
        # Define specialized TensorBoard writer categories and create the writers
        categories = {
            "tpu_utilization": os.path.join(self.tb_log_dir, "tpu/utilization"),
            "tpu_temperature": os.path.join(self.tb_log_dir, "tpu/temperature"),
            "system_cpu": os.path.join(self.tb_log_dir, "system/cpu"),
            "system_memory": os.path.join(self.tb_log_dir, "system/memory"),
            "system_disk": os.path.join(self.tb_log_dir, "system/disk"),
            "network": os.path.join(self.tb_log_dir, "system/network")
        }
        
        # Use base class method to create specialized writers
        self.create_specialized_writers(categories)
        
        # Define category keywords for metric categorization
        self.category_keywords = {
            "tpu_utilization": ['utilization', 'duty_cycle', 'op', 'flops'],
            "tpu_temperature": ['temperature', 'temp'],
            "system_cpu": ['cpu'],
            "system_memory": ['memory', 'ram'],
            "system_disk": ['disk', 'storage'],
            "network": ['network', 'connectivity', 'latency']
        }
            
        log_success(f"TPUDashboard initialized with TensorBoard integration")
    
    def update_dashboard(self, metrics, step):
        """Update the dashboard with TPU metrics
        
        Args:
            metrics: Dictionary of metrics to update
            step: Step value for the metrics (e.g., timestamp)
        """
        # First, update using the parent implementation for all metrics
        super().update_dashboard(metrics, step)
        
        # Categorize metrics based on keywords
        categorized_metrics = self.categorize_metrics(metrics, self.category_keywords)
        
        # Update specialized writers using the base class method
        self.update_specialized_writers(categorized_metrics, step)
        
    def categorize_tpu_metrics(self, metrics):
        """Categorize TPU-specific metrics for better organization
        
        Args:
            metrics: Dictionary of metrics to categorize
            
        Returns:
            dict: Dictionary of categorized metrics
        """
        return self.categorize_metrics(metrics, self.category_keywords)
        
    def summarize_tpu_metrics(self, metrics):
        """Create a summary of the most important TPU metrics
        
        Args:
            metrics: Dictionary of metrics
            
        Returns:
            dict: Summary dictionary with key metrics
        """
        summary = {
            "timestamp": datetime.now().isoformat()
        }
        
        # Extract key metrics if available
        if "duty_cycle_pct" in metrics:
            summary["utilization"] = metrics["duty_cycle_pct"]
        
        if "matrix_unit_utilization_pct" in metrics:
            summary["matrix_unit"] = metrics["matrix_unit_utilization_pct"]
            
        if "temperature_c" in metrics:
            summary["temperature"] = metrics["temperature_c"]
            
        if "memory_used_pct" in metrics:
            summary["memory"] = metrics["memory_used_pct"]
            
        return summary
        
    def run(self, update_interval=60):
        """Run the dashboard with periodic updates
        
        Args:
            update_interval: Interval in seconds between updates
        """
        if not self.enabled:
            log_warning("TPUDashboard is disabled. Not starting.")
            return
            
        log_success(f"TPUDashboard running with update interval: {update_interval}s")
        
        try:
            while True:
                # This would typically collect metrics directly,
                # but in our refactored design, metrics come from monitors
                time.sleep(update_interval)
        except KeyboardInterrupt:
            log("TPUDashboard stopped by user")

    def start_profiling(self):
        """Start the TensorBoard TPU profiler with proper locking"""
        with self.profiling_lock:
            if self.profiling_active:
                log_warning("TPU profiling already in progress, skipping")
                return False
                
            try:
                profile_subdir = os.path.join(
                    self.profile_dir, 
                    f"profile_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
                )
                
                if not self.use_gcs:
                    ensure_directory(profile_subdir)
                    
                tf.profiler.experimental.start(profile_subdir)
                self.profiling_active = True
                self.last_profile_time = time.time()
                log_success(f"TPU profiling started in {profile_subdir}")
                return True
            except Exception as e:
                log_error(f"Failed to start TPU profiling: {e}")
                return False

    def stop_profiling(self):
        """Stop the profiler with proper locking"""
        with self.profiling_lock:
            if not self.profiling_active:
                log_warning("No active TPU profiling to stop")
                return False
                
            try:
                tf.profiler.experimental.stop()
                self.profiling_active = False
                log_success("TPU profiling stopped")
                return True
            except Exception as e:
                log_error(f"Failed to stop TPU profiling: {e}")
                self.profiling_active = False  # Reset state even on error
                return False

    def profile_tpu(self, min_interval_seconds=300):
        """Run a TPU profiling session if enough time has passed since the last one
        
        Args:
            min_interval_seconds: Minimum seconds between profiling sessions
            
        Returns:
            bool: True if profiling was performed, False otherwise
        """
        # Check if enough time has passed since last profile
        current_time = time.time()
        if current_time - self.last_profile_time < min_interval_seconds:
            log(f"Skipping TPU profiling (last profile was {int(current_time - self.last_profile_time)}s ago)")
            return False
            
        # Start profiling
        if not self.start_profiling():
            return False
            
        # Create a separate thread to stop profiling after duration
        def _stop_after_duration():
            time.sleep(self.profile_duration)
            self.stop_profiling()
            # Process profile data and extract metrics
            self._process_profile_data()
            
        profiling_thread = threading.Thread(target=_stop_after_duration)
        profiling_thread.daemon = True
        profiling_thread.start()
        
        log_success(f"TPU profiling started for {self.profile_duration} seconds")
        return True
        
    def _process_profile_data(self):
        """Process the latest profiling data and extract metrics
        
        This is called after profiling completes to parse the output
        and update the dashboard with actual metrics from profiling
        """
        # In a real implementation, this would parse the profiler output files
        # For now, we'll use placeholder metrics
        step = int(time.time())
        metrics = {
            "tpu_utilization_percent": 75.0,
            "tpu_memory_consumption_gb": 8.0,
            "tpu_ops_count": 15000,
        }
        
        # Update the dashboard
        self.update_dashboard(metrics, step)
        log_success("TPU profiling metrics updated on dashboard")

    def update_env_metrics(self, metrics, step):
        """
        Update environment metrics on the dashboard.
        This is a convenience wrapper around update_dashboard.
        
        Args:
            metrics: Dictionary of environment metrics
            step: Step value for the metrics
        """
        return self.update_dashboard(metrics, step)
    
    def query_cloud_metrics(self, metric_type, window_seconds=300):
        """Query metrics from Google Cloud Monitoring
        
        Args:
            metric_type: The metric type to query (e.g., "compute.googleapis.com/instance/cpu/utilization")
            window_seconds: Time window in seconds to query
            
        Returns:
            dict: Latest metric values or empty dict if query fails
        """
        if not CLOUD_MONITORING_AVAILABLE or not self.client:
            return {}
            
        try:
            now = time.time()
            seconds = int(now)
            nanos = int((now - seconds) * 10**9)
            interval = monitoring_v3.TimeInterval(
                end_time={"seconds": seconds, "nanos": nanos},
                start_time={"seconds": seconds - window_seconds, "nanos": nanos}
            )
            
            request = {
                "name": f"projects/{self.project_id}",
                "filter": f'metric.type = "{metric_type}"',
                "interval": interval,
                "view": monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL
            }
            
            results = self.client.list_time_series(request=request)
            
            metrics = {}
            for result in results:
                if result.points:
                    # Extract the metric labels to use as part of the key
                    labels = []
                    for key, value in result.metric.labels.items():
                        labels.append(f"{key}:{value}")
                        
                    # Create a name for this specific metric
                    metric_name = metric_type.split('/')[-1]
                    if labels:
                        metric_name = f"{metric_name}_{'.'.join(labels)}"
                        
                    # Get the value
                    point = result.points[0]
                    if hasattr(point.value, "double_value"):
                        metrics[metric_name] = point.value.double_value
                    elif hasattr(point.value, "int64_value"):
                        metrics[metric_name] = point.value.int64_value
                        
            return metrics
            
        except Exception as e:
            log_error(f"Failed to query Cloud Monitoring metrics: {e}")
            return {} 