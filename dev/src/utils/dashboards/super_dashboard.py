import os
import time
import socket
import threading
import subprocess
from datetime import datetime
import tensorflow as tf

from .dashboard_interface import DashboardInterface, MetricsSubscriber
from ..logging.cls_logging import log, log_success, log_warning, log_error
from ..logging.config_loader import get_config
from ..logging.path_utils import resolve_path, ensure_directory, is_gcs_path

# Try to import Google Cloud Monitoring
try:
    from google.cloud import monitoring_v3
    from google.protobuf import timestamp_pb2
    from google.api import metric_pb2, resource_pb2
    CLOUD_MONITORING_AVAILABLE = True
except ImportError:
    CLOUD_MONITORING_AVAILABLE = False
    log_warning("Google Cloud Monitoring libraries not available; some features will be disabled.")

class Dashboard(DashboardInterface, MetricsSubscriber):
    """Base dashboard class for visualizing monitoring data using TensorBoard"""
    
    def __init__(self, name="base", tb_log_dir=None, use_gcs=None, config=None, config_path=None):
        """Initialize dashboard with TensorBoard log directory
        
        Args:
            name: Dashboard name (used for configuration lookup)
            tb_log_dir: Directory for TensorBoard logs (if None, use config)
            use_gcs: Whether to use GCS bucket for storage (if None, use config)
            config: Pre-loaded configuration (if None, load from config_path)
            config_path: Path to configuration file (if None, use default)
        """
        # Initialize MetricsSubscriber
        MetricsSubscriber.__init__(self)
        
        self.name = name.lower()
        
        # Load configuration (if not provided)
        if config is None:
            self.config = get_config(config_path)
        else:
            self.config = config
        
        # Get dashboard-specific configuration
        dashboard_config = self.config.get("dashboards", {}).get(f"{self.name}_dashboard", {})
        
        # Set up GCS usage (use parameter, or config value, or default)
        if use_gcs is None:
            use_gcs = self.config.get("use_gcs", False)
        self.use_gcs = use_gcs
        
        # Get TensorBoard directory from config or parameter
        if tb_log_dir is None:
            tb_log_dir = dashboard_config.get("tb_log_dir", self.name)
        
        # Get bucket name from config
        bucket_name = self.config.get("bucket_name")
        
        # Base directory for TensorBoard logs
        tensorboard_base = self.config.get("tensorboard_base", "tensorboard-logs/")
        
        # Set up the TensorBoard log directory
        self.tb_log_dir = resolve_path(
            tb_log_dir,
            base_dir=os.path.join("logs/tensorboard", ""),
            use_gcs=self.use_gcs,
            bucket_name=bucket_name,
            gcs_base_dir=tensorboard_base
        )
        
        # Create directory if using local path
        if not self.use_gcs:
            ensure_directory(self.tb_log_dir)
        
        try:
            # Create the TensorBoard writer
            self.writer = tf.summary.create_file_writer(self.tb_log_dir)
            log_success(f"Dashboard initialized with TensorBoard log directory: {self.tb_log_dir}")
        except Exception as e:
            log_error(f"Failed to initialize TensorBoard writer: {e}")
            self.writer = None
            
        # Initialize specialized writers (to be populated by subclasses)
        self.specialized_writers = {}
        self.categories = {}
        
        # Check if this dashboard is enabled in configuration
        self.enabled = dashboard_config.get("enabled", True)
        if not self.enabled:
            log_warning(f"{self.name.title()} Dashboard is disabled in configuration")
        
        # Initialize server process variable
        self.server_process = None
        self.server_host = None
        self.server_port = None
    
    def create_specialized_writers(self, categories):
        """Create specialized TensorBoard writers for different metric categories
        
        Args:
            categories: Dictionary mapping category names to relative paths
            
        Returns:
            dict: Dictionary of specialized writers
        """
        # Store category paths
        self.categories.update(categories)
        
        # Create writers for each category
        try:
            for category, path in self.categories.items():
                # For local paths, ensure the directory exists
                if not self.use_gcs and not is_gcs_path(path):
                    ensure_directory(path)
                
                # Create the writer
                self.specialized_writers[category] = tf.summary.create_file_writer(path)
                
            log_success(f"Created {len(categories)} specialized writers for {self.name} dashboard")
            return self.specialized_writers
        except Exception as e:
            log_error(f"Error creating specialized writers: {e}")
            return {}
    
    def update_dashboard(self, metrics, step=None):
        """Update the dashboard with new metrics.
        
        Args:
            metrics: Dictionary of metrics to update
            step: Step value for the metrics (e.g., timestamp)
        """
        if not self.enabled:
            return
        
        if step is None:
            step = int(time.time())
        
        try:
            # Write metrics to main writer
            with self.writer.as_default():
                for key, value in metrics.items():
                    if isinstance(value, (int, float)):
                        tf.summary.scalar(key, value, step=step)
            
            # Flush the writer
            self.writer.flush()
        except Exception as e:
            log_error(f"Error updating dashboard: {e}")
    
    def update_specialized_writers(self, categorized_metrics, step=None):
        """Update specialized writers with categorized metrics.
        
        Args:
            categorized_metrics: Dictionary mapping categories to metric dictionaries
            step: Step value for the metrics
        """
        if not self.enabled:
            return
        
        if step is None:
            step = int(time.time())
        
        try:
            for category, metrics in categorized_metrics.items():
                if category in self.specialized_writers:
                    writer = self.specialized_writers[category]
                    
                    if not metrics:
                        continue
                    
                    with writer.as_default():
                        for key, value in metrics.items():
                            if isinstance(value, (int, float)):
                                tf.summary.scalar(key, value, step=step)
                    
                    # Flush the writer
                    writer.flush()
        except Exception as e:
            log_error(f"Error updating specialized writers: {e}")
    
    def categorize_metrics(self, metrics, category_keywords):
        """Categorize metrics based on keywords.
        
        Args:
            metrics: Dictionary of metrics
            category_keywords: Dictionary mapping categories to lists of keywords
            
        Returns:
            dict: Dictionary mapping categories to metric dictionaries
        """
        result = {category: {} for category in category_keywords}
        
        for key, value in metrics.items():
            if not isinstance(value, (int, float)):
                continue
                
            # Check each category for matching keywords
            categorized = False
            for category, keywords in category_keywords.items():
                for keyword in keywords:
                    if keyword.lower() in key.lower():
                        result[category][key] = value
                        categorized = True
                        break
                
                if categorized:
                    break
        
        return result
    
    def start(self, port=6006, host="0.0.0.0"):
        """Start the TensorBoard server.
        
        Args:
            port: Port to bind the server to
            host: Host to bind the server to
            
        Returns:
            bool: True if successful, False otherwise
        """
        if not self.enabled:
            log_warning(f"{self.name} Dashboard is disabled. Not starting server.")
            return False
        
        if self.server_process and self.server_process.poll() is None:
            log_warning(f"TensorBoard server is already running on {self.server_host}:{self.server_port}")
            return True
        
        try:
            # Store connection info
            self.server_host = host
            self.server_port = port
            
            # Build command
            cmd = [
                "tensorboard",
                "--logdir", self.tb_log_dir,
                "--host", host,
                "--port", str(port)
            ]
            
            # Start TensorBoard server
            self.server_process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            
            # Wait a moment for the server to start
            time.sleep(2)
            
            # Check if process is still running
            if self.server_process.poll() is None:
                log_success(f"TensorBoard server started on http://{host}:{port}")
                return True
            else:
                # Process exited early, get error message
                _, stderr = self.server_process.communicate()
                log_error(f"TensorBoard server failed to start: {stderr}")
                self.server_process = None
                return False
                
        except Exception as e:
            log_error(f"Error starting TensorBoard server: {e}")
            self.server_process = None
            return False
    
    def stop(self):
        """Stop the TensorBoard server.
        
        Returns:
            bool: True if successful, False otherwise
        """
        if not self.server_process:
            return True
        
        try:
            # Check if process is running
            if self.server_process.poll() is None:
                # Send terminate signal
                self.server_process.terminate()
                
                # Wait for process to finish (with timeout)
                try:
                    self.server_process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    # Force kill if it didn't terminate gracefully
                    self.server_process.kill()
                    self.server_process.wait(timeout=2)
            
            log_success("TensorBoard server stopped")
            self.server_process = None
            return True
            
        except Exception as e:
            log_error(f"Error stopping TensorBoard server: {e}")
            return False
    
    def get_url(self):
        """Get the URL to access the dashboard.
        
        Returns:
            str: URL to access the dashboard, or None if not running
        """
        if not self.server_process or self.server_process.poll() is not None:
            return None
        
        if self.server_host == "0.0.0.0":
            # Use actual hostname for better usability
            hostname = socket.gethostname()
            return f"http://{hostname}:{self.server_port}"
        else:
            return f"http://{self.server_host}:{self.server_port}"
    
    def __enter__(self):
        """Context manager entry.
        
        Returns:
            self: Returns self for use in context manager
        """
        self.start()
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit."""
        # Unsubscribe from all publishers
        self.unsubscribe_all()
        
        # Stop the server
        self.stop()
    
    def __del__(self):
        """Destructor to ensure resources are cleaned up."""
        self.stop()


class SuperDashboard(Dashboard):
    """Unified dashboard that aggregates specialized dashboards for TensorBoard visualization"""
    
    def __init__(self, tb_log_dir=None, use_gcs=None, config_path=None):
        """Initialize the super dashboard
        
        Args:
            tb_log_dir: Base directory for TensorBoard logs (if None, use config)
            use_gcs: Whether to use GCS bucket for storage (if None, use config)
            config_path: Path to configuration file (if None, use default)
        """
        # Initialize base dashboard
        super().__init__(name="super", tb_log_dir=tb_log_dir, use_gcs=use_gcs, config_path=config_path)
        
        # Initialize collections
        self.dashboards = {}
        self.monitors = {}
        
        # Get super dashboard config
        dashboard_config = self.config.get("dashboards", {}).get("super_dashboard", {})
        self.update_interval = dashboard_config.get("update_interval", 60)
        
        log_success(f"SuperDashboard initialized with update interval: {self.update_interval}s")
        
    def add_dashboard(self, name, dashboard):
        """Add a specialized dashboard to the super dashboard
        
        Args:
            name: Name for the dashboard
            dashboard: Dashboard instance
            
        Returns:
            self: Returns self for method chaining
        """
        self.dashboards[name.lower()] = dashboard
        log_success(f"Added {name} dashboard to SuperDashboard")
        return self
    
    def add_monitor(self, name, monitor, dashboard_name=None):
        """Add a monitor to the super dashboard and link to specific dashboard
        
        Args:
            name: Name for the monitor
            monitor: Monitor instance
            dashboard_name: Name of dashboard to link (if None, use name)
            
        Returns:
            self: Returns self for method chaining
        """
        # Store the monitor
        self.monitors[name.lower()] = monitor
        
        # Link the monitor to its dashboard (if available)
        dashboard_name = dashboard_name or name
        if dashboard_name.lower() in self.dashboards:
            monitor.set_dashboard(self.dashboards[dashboard_name.lower()])
            log_success(f"Linked {name} monitor to {dashboard_name} dashboard")
        
        log_success(f"Added {name} monitor to SuperDashboard")
        return self
    
    def update_all(self, tpu_metrics=None, gcs_metrics=None, env_metrics=None, step=None):
        """
        Update all specialized dashboards with their respective metrics.
        
        Args:
            tpu_metrics: Dictionary of TPU metrics
            gcs_metrics: Dictionary of GCS transfer metrics
            env_metrics: Dictionary of environment metrics
            step: A numeric step value (e.g. timestamp) for logging
        """
        step = step or int(time.time())
        all_metrics = {}
        
        # Update each dashboard with its metrics
        if tpu_metrics and "tpu" in self.dashboards:
            self.dashboards["tpu"].update_dashboard(tpu_metrics, step)
            all_metrics.update({f"tpu_{k}": v for k, v in tpu_metrics.items()})
        
        if gcs_metrics and "bucket" in self.dashboards:
            self.dashboards["bucket"].update_dashboard(gcs_metrics, step)
            all_metrics.update({f"gcs_{k}": v for k, v in gcs_metrics.items()})
        
        if env_metrics and "environment" in self.dashboards:
            self.dashboards["environment"].update_dashboard(env_metrics, step)
            all_metrics.update({f"env_{k}": v for k, v in env_metrics.items()})
        
        # Update super dashboard with all metrics
        if all_metrics:
            self.update_dashboard(all_metrics, step)
            log_success("SuperDashboard updated with all metrics")
    
    def start_all_monitors(self, save_interval=5):
        """Start all attached monitors
        
        Args:
            save_interval: How often to save samples (in minutes)
            
        Returns:
            bool: Success status
        """
        status = True
        for name, monitor in self.monitors.items():
            if not monitor.start_monitoring(save_interval):
                log_error(f"Failed to start {name} monitor")
                status = False
        
        if status:
            log_success(f"Started all monitors (save interval: {save_interval} minutes)")
        
        return status
    
    def stop_all_monitors(self):
        """Stop all attached monitors
        
        Returns:
            bool: Success status
        """
        status = True
        for name, monitor in self.monitors.items():
            if not monitor.stop_monitoring_thread():
                log_error(f"Failed to stop {name} monitor cleanly")
                status = False
        
        return status
    
    def run(self, update_interval=60):
        """Run the super dashboard with periodic updates
        
        Args:
            update_interval: How often to update dashboards (in seconds)
        """
        # Start all monitors
        self.start_all_monitors()
        
        log_success(f"SuperDashboard running with update interval: {update_interval}s")
        
        try:
            while True:
                # Update from all monitors
                for name, monitor in self.monitors.items():
                    # Get the current metrics from the monitor
                    info = monitor.collect_info()
                    sample = monitor._process_sample(info)
                    
                    # Update corresponding dashboard
                    metrics = sample.get("metrics", {})
                    if name.lower() == "tpu":
                        self.update_all(tpu_metrics=metrics, step=int(time.time()))
                    elif name.lower() == "bucket":
                        self.update_all(gcs_metrics=metrics, step=int(time.time()))
                    
                # Sleep for the update interval
                time.sleep(update_interval)
        except KeyboardInterrupt:
            log("SuperDashboard stopped by user")
        finally:
            # Stop all monitors
            self.stop_all_monitors() 