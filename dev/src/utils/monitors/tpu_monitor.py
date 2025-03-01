"""
TPU monitoring for TPU VMs, providing both system metrics and TPU-specific monitoring.
"""
import os
import json
import psutil
import socket
import time
import threading
import tensorflow as tf
from datetime import datetime

from ..logging.cls_logging import log, log_success, log_warning, log_error, run_shell_command, ensure_directory
from ..logging.config_loader import get_config
from .super_monitor import SuperMonitor

# Try to import Google Cloud Monitoring
try:
    from google.cloud import monitoring_v3
    CLOUD_MONITORING_AVAILABLE = True
except ImportError:
    CLOUD_MONITORING_AVAILABLE = False
    log_warning("Google Cloud Monitoring libraries not available; falling back to local metrics.")

class TPUMonitor(SuperMonitor):
    """Monitor TPU resources and system environment"""
    
    def __init__(self, log_dir=None, sampling_interval=None, monitor_tpu=None, monitor_env=None, config=None, config_path=None):
        """
        Initialize TPU monitor.
        
        Args:
            log_dir: Directory to store monitoring logs (if None, use config)
            sampling_interval: Interval (in seconds) between samples (if None, use config)
            monitor_tpu: Whether to monitor TPU resources (if None, use config)
            monitor_env: Whether to monitor environment resources (if None, use config)
            config: Pre-loaded configuration (if None, load from config_path)
            config_path: Path to configuration file (if None, use default)
        """
        # Initialize base monitor
        super().__init__(name="TPU", log_dir=log_dir, sampling_interval=sampling_interval, config=config, config_path=config_path)
        
        # Get TPU-specific configuration with defaults
        tpu_config = self.config.get("tpu_monitor", {})
        self.monitor_tpu = monitor_tpu if monitor_tpu is not None else tpu_config.get("monitor_tpu", True)
        self.monitor_env = monitor_env if monitor_env is not None else tpu_config.get("monitor_env", True)
        
        # Get TensorBoard log directory from config
        tb_log_dir = tpu_config.get("tb_log_dir", "tpu")
        tensorboard_base = self.config.get("tensorboard_base", "tensorboard-logs/")
        self.tb_log_dir = os.path.join("logs/tensorboard", tb_log_dir)
        
        # Initialize Cloud Monitoring if available
        if CLOUD_MONITORING_AVAILABLE:
            try:
                self.client = monitoring_v3.MetricServiceClient()
                # Get project ID from config or environment
                project_id = self.config.get("google_cloud", {}).get("project_id")
                self.project_name = f"projects/{project_id}" if project_id else None
                log_success("Cloud Monitoring client initialized in TPUMonitor.")
            except Exception as e:
                log_warning(f"Failed to initialize Cloud Monitoring client: {e}")
                self.client = None
                self.project_name = None
            
        # Create a TensorBoard writer for internal use
        ensure_directory(self.tb_log_dir)
        self.tb_writer = tf.summary.create_file_writer(self.tb_log_dir)
        
        log_success(f"TPUMonitor initialized with monitor_tpu={self.monitor_tpu}, monitor_env={self.monitor_env}")

    def set_bucket_name(self, bucket_name):
        """Set GCS bucket name to monitor
        
        Args:
            bucket_name: Name of the GCS bucket
            
        Returns:
            self: Returns self for method chaining
        """
        # Use base class implementation
        return super().set_bucket_name(bucket_name)
    
    def get_metrics(self):
        """Get TPU metrics.
        
        Returns:
            dict: Dictionary of TPU and system metrics
        """
        metrics = super().get_metrics()
        
        # Collect TPU specific metrics if enabled
        if self.monitor_tpu:
            tpu_metrics = self.check_tpu_devices()
            metrics.update(tpu_metrics)
        
        # Collect environment metrics if enabled
        if self.monitor_env:
            env_metrics = self.check_environment()
            metrics.update(env_metrics)
        
        return metrics
    
    #
    # TPU-specific monitoring methods
    #
    
    def check_tpu_devices(self):
        """Check TPU devices and their properties
        
        Returns:
            dict: TPU devices information and status
        """
        result = {
            "timestamp": datetime.now().isoformat(),
            "status": "unknown",
        }
        
        try:
            # Use TensorFlow to check TPU devices
            physical_devices = tf.config.list_physical_devices('TPU')
            
            if physical_devices:
                result["status"] = "available"
                result["tpu_device_count"] = len(physical_devices)
                
                # Get detailed TPU information using XLA
                try:
                    import tensorflow.experimental.numpy as tnp
                    tpu_util = tnp.core.tpu.tpu_util
                    tpu_info = tpu_util.initialize_tpu_system()
                    
                    result["tpu_cores"] = tpu_info.topology.num_cores
                    result["tpu_version"] = f"v{tpu_info.topology.version}"
                    
                    # Get TPU utilization
                    try:
                        tpu_util = self._get_tpu_utilization()
                        if tpu_util is not None:
                            result.update(tpu_util)
                    except Exception as e:
                        log_warning(f"Error getting TPU utilization: {e}")
                
                except Exception as e:
                    log_warning(f"Error getting detailed TPU information: {e}")
            else:
                result["status"] = "not_available"
                result["tpu_device_count"] = 0
                
        except Exception as e:
            result["status"] = "error"
            result["error_message"] = str(e)
            log_error(f"Error checking TPU devices: {e}")
            
        return result
    
    def _get_tpu_utilization(self):
        """Get TPU utilization metrics
        
        Returns:
            dict: TPU utilization metrics
        """
        # Try to get metrics from Cloud Monitoring API first
        if self.cloud_monitor.is_available() and self.cloud_monitor.project_name:
            try:
                # Query Cloud Monitoring for TPU metrics
                tpu_metrics = self.cloud_monitor.get_metric_data(
                    metric_type="tpu.googleapis.com/util/duty_cycle",
                    resource_type="tpu_node",
                    lookback_minutes=5
                )
                
                if tpu_metrics:
                    # Process and return the metrics
                    result = {}
                    for key, values in tpu_metrics.items():
                        if values:
                            # Use the most recent value
                            timestamp, value = values[0]
                            result[f"tpu_duty_cycle_{key}"] = value
                    
                    if result:
                        # Calculate average utilization across all TPU chips
                        values = [v for k, v in result.items() if k.startswith("tpu_duty_cycle_")]
                        if values:
                            result["tpu_avg_duty_cycle"] = sum(values) / len(values)
                            
                        return result
            except Exception as e:
                log_warning(f"Error getting TPU utilization from Cloud Monitoring: {e}")
        
        # Fall back to lscpu or other commands
        try:
            # Use shell command to get TPU information on TPU VMs
            cmd = "lscpu | grep -i TPU"
            returncode, output = self._run_command(cmd)
            
            if returncode == 0 and output:
                # Parse the output
                result = {}
                for line in output.strip().split("\n"):
                    if ":" in line:
                        key, value = line.split(":", 1)
                        key = key.strip().lower().replace(" ", "_")
                        value = value.strip()
                        result[f"tpu_{key}"] = value
                
                return result
        except Exception as e:
            log_warning(f"Error getting TPU utilization from lscpu: {e}")
        
        # Return empty dict if no metrics available
        return {}
    
    def check_environment(self):
        """Check system environment (CPU, memory, disk)
        
        Returns:
            dict: System environment metrics
        """
        result = {
            "system_hostname": socket.gethostname(),
            "timestamp": datetime.now().isoformat()
        }
        
        try:
            # CPU metrics
            cpu_percent = psutil.cpu_percent(interval=1)
            cpu_count = psutil.cpu_count()
            result["cpu_percent"] = cpu_percent
            result["cpu_count"] = cpu_count
            
            # Memory metrics
            memory = psutil.virtual_memory()
            result["memory_total_gb"] = round(memory.total / (1024**3), 2)
            result["memory_used_gb"] = round(memory.used / (1024**3), 2)
            result["memory_percent"] = memory.percent
            
            # Disk metrics
            disk = psutil.disk_usage("/")
            result["disk_total_gb"] = round(disk.total / (1024**3), 2)
            result["disk_used_gb"] = round(disk.used / (1024**3), 2)
            result["disk_percent"] = disk.percent
            
            # Network metrics
            net_io = psutil.net_io_counters()
            result["net_bytes_sent"] = net_io.bytes_sent
            result["net_bytes_recv"] = net_io.bytes_recv
            
            # Calculate network rates if possible
            if hasattr(self, 'prev_net_io') and hasattr(self, 'prev_net_time'):
                time_diff = time.time() - self.prev_net_time
                if time_diff > 0:
                    sent_rate = (net_io.bytes_sent - self.prev_net_io.bytes_sent) / time_diff
                    recv_rate = (net_io.bytes_recv - self.prev_net_io.bytes_recv) / time_diff
                    result["net_send_rate_mbps"] = round(sent_rate / (1024**2) * 8, 2)
                    result["net_recv_rate_mbps"] = round(recv_rate / (1024**2) * 8, 2)
            
            # Store current values for next calculation
            self.prev_net_io = net_io
            self.prev_net_time = time.time()
            
        except Exception as e:
            log_error(f"Error getting environment metrics: {e}")
        
        return result
    
    def _run_command(self, cmd):
        """Run a shell command and return the output
        
        Args:
            cmd: Command to run
            
        Returns:
            tuple: (return_code, output)
        """
        import subprocess
        
        try:
            process = subprocess.Popen(
                cmd, 
                shell=True, 
                stdout=subprocess.PIPE, 
                stderr=subprocess.PIPE
            )
            stdout, stderr = process.communicate()
            return process.returncode, stdout.decode()
        except Exception as e:
            return -1, str(e)
    
    #
    # Environment monitoring methods
    #
    
    def collect_system_info(self):
        """Collect basic system information"""
        info = {
            "timestamp": datetime.now().isoformat(),
            "platform": {
                "system": os.name,
                "hostname": socket.gethostname(),
                "cpu_count": psutil.cpu_count(logical=True),
                "physical_cpu_count": psutil.cpu_count(logical=False),
            },
            "memory": {
                "total_gb": round(psutil.virtual_memory().total / (1024**3), 2),
                "available_gb": round(psutil.virtual_memory().available / (1024**3), 2),
                "percent_used": psutil.virtual_memory().percent
            },
            "disk": {
                "total_gb": round(psutil.disk_usage('/').total / (1024**3), 2),
                "free_gb": round(psutil.disk_usage('/').free / (1024**3), 2),
                "percent_used": psutil.disk_usage('/').percent
            },
            "environment_variables": {
                k: v for k, v in os.environ.items() 
                if any(prefix in k for prefix in ["TPU", "XLA", "PYTHONPATH", "PATH", "LD_LIBRARY"])
            }
        }
        
        # Check CPU utilization
        info["cpu"] = {
            "percent_used": psutil.cpu_percent(interval=1)
        }
        
        return info
    
    #
    # Network monitoring methods
    #
    
    # Using base class implementation for check_network_connectivity
    
    # Using base class implementation for check_gcs_bucket_access
    
    #
    # Main monitoring methods
    #
    
    def collect_info(self):
        """Collect system and TPU resource information (implements base method)
        
        Returns:
            dict: Collected information about TPU and system resources
        """
        info = {
            "timestamp": datetime.now().isoformat(),
            "tpu": None,
            "system": self.collect_system_info() if self.monitor_env else None,
            "network": None
        }
        
        # Add TPU information if available
        if self.monitor_tpu:
            tpu_info = {}
            
            # Add TPU devices
            if self.has_tpu:
                tpu_devices = self.check_tpu_devices()
                if tpu_devices:
                    tpu_info["devices"] = tpu_devices
                
                # Add TPU utilization
                utilization = self._get_tpu_utilization()
                if utilization:
                    tpu_info["utilization"] = utilization
            
            info["tpu"] = tpu_info
        
        # Add network information if monitoring environment
        if self.monitor_env:
            # Use the base class implementation for network connectivity
            info["network"] = {
                "connectivity": super().check_network_connectivity(),
                "stats": super().check_network_stats()
            }
            
            # Check bucket access if we have a bucket name and are monitoring env
            if self.bucket_name:
                info["bucket"] = super().check_gcs_bucket_access(self.bucket_name)
        
        return info

    def _add_standard_metrics(self, standard_metrics, info):
        """Add metrics to the standard format (implements base method)"""
        # Set overall status initially to ok
        standard_metrics["status"] = "ok"
        metrics = standard_metrics["metrics"]
        
        # Add system metrics if we collected them
        if self.monitor_env and "system_info" in info:
            system_info = info["system_info"]
            
            # CPU metrics
            if "cpu" in system_info:
                metrics["cpu_utilization_percent"] = system_info["cpu"]["percent_used"]
            
            # Memory metrics
            if "memory" in system_info:
                memory = system_info["memory"]
                metrics["memory_total_gb"] = memory.get("total_gb", 0)
                metrics["memory_available_gb"] = memory.get("available_gb", 0)
                metrics["memory_percent_used"] = memory.get("percent_used", 0)
                metrics["memory_used_gb"] = round(memory.get("total_gb", 0) - memory.get("available_gb", 0), 2)
            
            # Disk metrics
            if "disk" in system_info:
                disk = system_info["disk"]
                metrics["disk_total_gb"] = disk.get("total_gb", 0)
                metrics["disk_free_gb"] = disk.get("free_gb", 0)
                metrics["disk_percent_used"] = disk.get("percent_used", 0)
                metrics["disk_used_gb"] = round(disk.get("total_gb", 0) - disk.get("free_gb", 0), 2)
            
            # Add hostname and system metadata
            if "platform" in system_info:
                platform = system_info["platform"]
                standard_metrics["metadata"]["hostname"] = platform.get("hostname", "unknown")
                standard_metrics["metadata"]["system"] = platform.get("system", "unknown")
                metrics["cpu_count"] = platform.get("cpu_count", 0)
                metrics["physical_cpu_count"] = platform.get("physical_cpu_count", 0)
        
        # Add TPU metrics if we collected them
        if self.monitor_tpu:
            # Add TPU device count if available
            if "tpu_devices" in info:
                device_info = info["tpu_devices"]
                if device_info["status"] == "available":
                    metrics["tpu_device_count"] = device_info.get("tpu_device_count", 0)
                    standard_metrics["metadata"]["tpu_available"] = True
                else:
                    metrics["tpu_device_count"] = 0
                    standard_metrics["metadata"]["tpu_available"] = False
                    standard_metrics["status"] = "warning"  # Change overall status if TPU not available
            
            # TPU utilization metrics
            if "tpu_utilization" in info:
                util_info = info["tpu_utilization"]
                if util_info["status"] == "available":
                    # Extract duty cycle or other metrics
                    for key, value in util_info.items():
                        if key not in ["timestamp", "status", "raw_output", "error", "parsing_error"] and isinstance(value, (int, float)):
                            metrics[f"tpu_{key.lower().replace(' ', '_')}"] = value
        
        # Log metrics to TensorBoard
        try:
            with self.tb_writer.as_default():
                for key, value in metrics.items():
                    if isinstance(value, (int, float)):
                        tf.summary.scalar(key, value, step=int(time.time()))
                self.tb_writer.flush()
        except Exception as e:
            log_warning(f"Failed to log metrics to TensorBoard: {e}") 