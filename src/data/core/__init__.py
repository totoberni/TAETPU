"""
Core data handling functionality.

This module provides core functionality for configuration loading and dataset access.
"""

from .config_loader import (
    load_config,
    get_datasets_config,
    get_dataset_keys,
    get_dataset_info,
    get_dataset_name,
    resolve_config_path
) 