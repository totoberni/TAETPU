"""
Logging and configuration utilities for the TPU monitoring system.

This package provides logging functions, configuration loading,
and directory handling for the monitoring system.
"""

__version__ = "0.1.0"

# Import logging functions
from .cls_logging import (
    setup_logger, create_progress_bar, ensure_directory, ensure_directories,
    log, log_success, log_warning, log_error, run_shell_command
)

# Import configuration utilities
from .config_loader import (
    get_config, get_project_root, resolve_env_vars_in_config
)

# Define what's imported with `from utils.logging import *`
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
] 