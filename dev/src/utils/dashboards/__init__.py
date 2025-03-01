"""
Dashboard modules for visualizing TPU performance and bucket metrics.

This package provides classes for creating TensorBoard-based dashboards
to visualize TPU workloads and GCS bucket usage metrics.
"""

__version__ = "0.1.0"

# Import dashboard interfaces
from .dashboard_interface import DashboardInterface, MetricsSubscriber

# Import dashboard classes
from .super_dashboard import Dashboard, SuperDashboard
from .tpu_dashboard import TPUDashboard
from .bucket_dashboard import BucketDashboard

# Import dashboard utilities
from .start_dashboard import start_tensorboard, start_dashboards

# Define what's imported with `from utils.dashboards import *`
__all__ = [
    "DashboardInterface",
    "MetricsSubscriber",
    "Dashboard",
    "SuperDashboard",
    "TPUDashboard",
    "BucketDashboard",
    "start_tensorboard",
    "start_dashboards"
] 