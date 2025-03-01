"""
Utility modules for TPU monitoring, logging, and experiment tracking.

This package provides utilities for monitoring TPU performance, logging,
environment monitoring, and data flow tracking for Transformer ablation
experiments.
"""

__version__ = "0.1.0"

import os
import sys
import importlib.util

def ensure_imports():
    """
    Ensure that imports work correctly by setting up path properly.
    Call this function at the beginning of scripts to standardize import behavior.
    """
    # Get the current file's directory
    current_dir = os.path.dirname(os.path.abspath(__file__))
    
    # Add src directory to path to make imports work
    src_dir = os.path.dirname(current_dir)
    if src_dir not in sys.path:
        sys.path.insert(0, src_dir)
    
    # Add dev directory to path if it exists
    dev_dir = os.path.dirname(src_dir)
    if os.path.basename(dev_dir) == 'dev' and dev_dir not in sys.path:
        sys.path.insert(0, dev_dir)
    
    return True

# Run the import preparation when the utils module is imported
ensure_imports()

# Import from the logging package
from .logging import (
    setup_logger, create_progress_bar, ensure_directory, ensure_directories,
    log, log_success, log_warning, log_error, run_shell_command,
    get_config, get_project_root, resolve_env_vars_in_config
)

# Import monitor classes
from .monitors import (
    MonitorInterface, MetricsPublisher,
    SuperMonitor, TPUMonitor, BucketMonitor,
    CloudMonitoringClient
)

# Import dashboard classes
from .dashboards import (
    DashboardInterface, MetricsSubscriber,
    Dashboard, SuperDashboard, TPUDashboard, BucketDashboard,
    start_tensorboard, start_dashboards
)

# Import API integration utilities - use try/except to make API optional
try:
    from .api import (
        export_metrics_to_json, create_webapp_metrics, 
        configure_webapp_export, archive_metrics
    )
    API_AVAILABLE = True
except ImportError:
    API_AVAILABLE = False

# Define what's imported with `from utils import *`
__all__ = [
    # Logging functions
    "setup_logger",
    "create_progress_bar",
    "ensure_directory",
    "ensure_directories",
    "log",
    "log_success", 
    "log_warning", 
    "log_error",
    "run_shell_command",
    
    # Configuration utilities
    "get_config",
    "get_project_root",
    "resolve_env_vars_in_config",
    
    # Monitor interfaces
    "MonitorInterface",
    "MetricsPublisher",
    
    # Monitor classes
    "SuperMonitor", 
    "TPUMonitor",
    "BucketMonitor",
    "CloudMonitoringClient",
    
    # Dashboard interfaces
    "DashboardInterface",
    "MetricsSubscriber",
    
    # Dashboard classes
    "Dashboard",
    "SuperDashboard",
    "TPUDashboard",
    "BucketDashboard",
    
    # Dashboard utilities
    "start_tensorboard",
    "start_dashboards"
]

# Add API utilities to __all__ if available
if API_AVAILABLE:
    __all__.extend([
        "export_metrics_to_json",
        "create_webapp_metrics",
        "configure_webapp_export",
        "archive_metrics"
    ])