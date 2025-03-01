"""
API modules for the TPU monitoring system.

This package provides a Flask-based API server and utilities for exporting
metrics in web-friendly formats.
"""

__version__ = "0.1.0"

# Import API classes and functions
from .webapp_api import configure, start_server
from .webapp_integration import (
    configure_webapp_export, export_metrics_to_json,
    create_webapp_metrics, archive_metrics
)

# Define what's imported with `from utils.api import *`
__all__ = [
    # API server functions
    "configure",
    "start_server",
    
    # Integration utilities
    "configure_webapp_export",
    "export_metrics_to_json",
    "create_webapp_metrics",
    "archive_metrics"
] 