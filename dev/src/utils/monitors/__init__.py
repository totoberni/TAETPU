"""
Monitoring modules for TPU performance, bucket usage, and data flow tracking.

This package provides classes for monitoring TPU workloads, GCS bucket usage,
and tracking data flow for Transformer ablation experiments.
"""

__version__ = "0.1.0"

# Import monitor interfaces and base classes
from .monitor_interface import MonitorInterface, MetricsPublisher

# Import monitor classes
from .super_monitor import SuperMonitor
from .tpu_monitor import TPUMonitor
from .bucket_monitor import BucketMonitor
from .cloud_monitor import CloudMonitoringClient

# Define what's imported with `from utils.monitors import *`
__all__ = [
    "MonitorInterface",
    "MetricsPublisher",
    "SuperMonitor",
    "TPUMonitor", 
    "BucketMonitor",
    "CloudMonitoringClient"
]

# Instead of directly importing start_monitoring (which creates a circular reference),
# we define a function to get it dynamically when needed
def get_start_monitoring():
    """
    Dynamically import and return the start_monitoring function.
    This prevents circular import issues while still providing access to the function.
    """
    import importlib
    
    for module_path in ["dev.src.start_monitoring", "src.start_monitoring"]:
        try:
            module = importlib.import_module(module_path)
            if hasattr(module, "start_monitoring"):
                return module.start_monitoring
        except ImportError:
            continue
            
    # If no implementation is found, return a function that raises an error
    def missing_start_monitoring(*args, **kwargs):
        raise ImportError("Could not import start_monitoring function")
    
    return missing_start_monitoring 