"""
Configuration utilities for loading settings from YAML files.
Provides consistent configuration loading across the codebase.
"""
import os
import re
import yaml
from pathlib import Path
from typing import Dict, Any, Optional, List, Union

from .cls_logging import log, log_success, log_warning, log_error

# Standard location for config file
CONFIG_PATH = "dev/src/utils/logging/log_config.yaml"

# Global configuration cache
_CONFIG_CACHE = {}

def get_project_root() -> Path:
    """
    Get the project root directory.
    
    Returns:
        Path: Project root directory
    """
    # Use the parent of the current file's directory
    file_dir = Path(__file__).resolve().parent
    return file_dir.parent.parent.parent  # utils/logging -> utils -> src -> root

def load_yaml_config() -> Dict[str, Any]:
    """
    Load configuration from the YAML file.
    
    Returns:
        Configuration dictionary
    """
    config_path = str(get_project_root() / CONFIG_PATH)
    
    try:
        with open(config_path, 'r') as f:
            config = yaml.safe_load(f)
        
        if config is None:
            config = {}
        
        log_success(f"Loaded configuration from {config_path}")
        return config
    except Exception as e:
        log_error(f"Failed to load configuration from {config_path}: {e}")
        return {}

def resolve_env_vars_in_config(config: Dict[str, Any]) -> Dict[str, Any]:
    """
    Resolve environment variables in configuration values.
    Replaces ${VAR} or $VAR with the value of the environment variable.
    Also handles defaults with ${VAR:-default}.
    
    Args:
        config: Configuration dictionary
        
    Returns:
        Configuration with environment variables resolved
    """
    def resolve_value(value):
        if isinstance(value, str):
            # Replace ${VAR} or $VAR with environment variables
            def replace_var(match):
                var_name = match.group(1) or match.group(3)
                default = match.group(2) or ''
                return os.environ.get(var_name, default)
            
            # Handle ${VAR:-default} format first
            value = re.sub(r'\${([A-Za-z0-9_]+):-([^}]*)}', replace_var, value)
            # Then handle ${VAR} format
            value = re.sub(r'\${([A-Za-z0-9_]+)}', replace_var, value)
            # Finally handle $VAR format
            value = re.sub(r'\$([A-Za-z0-9_]+)', replace_var, value)
            return value
        elif isinstance(value, dict):
            return {k: resolve_value(v) for k, v in value.items()}
        elif isinstance(value, list):
            return [resolve_value(item) for item in value]
        else:
            return value
    
    return resolve_value(config)

def get_config(use_cache: bool = True) -> Dict[str, Any]:
    """
    Get configuration, loading from the YAML file and resolving environment variables.
    
    Args:
        use_cache: Whether to use cached configuration (if available)
        
    Returns:
        Configuration dictionary
    """
    global _CONFIG_CACHE
    
    # Check cache first if enabled
    if use_cache and _CONFIG_CACHE:
        return _CONFIG_CACHE
    
    # Load configuration
    config = load_yaml_config()
    
    # Resolve environment variables
    config = resolve_env_vars_in_config(config)
    
    # Cache the configuration if enabled
    if use_cache:
        _CONFIG_CACHE = config
    
    return config

def clear_config_cache():
    """Clear the configuration cache"""
    global _CONFIG_CACHE
    _CONFIG_CACHE = {}

def resolve_path(path: str, base_dir: Optional[Union[str, Path]] = None) -> str:
    """
    Resolve a path, handling GCS paths and relative paths.
    
    Args:
        path: Path to resolve
        base_dir: Base directory for relative paths (default: current directory)
        
    Returns:
        Resolved path
    """
    if not path:
        return path
    
    # Handle GCS paths (gs://)
    if path.startswith('gs://'):
        return path
    
    # Handle absolute paths
    if os.path.isabs(path):
        return path
    
    # Handle relative paths
    if base_dir is None:
        base_dir = os.getcwd()
    
    return os.path.normpath(os.path.join(str(base_dir), path))

def get_log_dir(config: Optional[Dict[str, Any]] = None) -> str:
    """
    Get the log directory from configuration.
    
    Args:
        config: Configuration dictionary (if None, will load from standard location)
        
    Returns:
        Log directory path
    """
    if config is None:
        config = get_config()
    
    # Check for log directory in config
    log_dir = config.get('base_log_dir')
    
    if not log_dir:
        log_dir = config.get('logging', {}).get('log_dir')
    
    if not log_dir:
        log_dir = 'logs'  # Default fallback
    
    # Resolve path
    return resolve_path(log_dir)

def get_tensorboard_dir(config: Optional[Dict[str, Any]] = None) -> str:
    """
    Get the TensorBoard directory from configuration.
    
    Args:
        config: Configuration dictionary (if None, will load from standard location)
        
    Returns:
        TensorBoard directory path
    """
    if config is None:
        config = get_config()
    
    # Get TensorBoard base directory from config
    tb_dir = config.get('tensorboard_base')
    
    if not tb_dir:
        tb_dir = 'tensorboard-logs/'
    
    # Resolve path
    return resolve_path(tb_dir)

def ensure_directory(directory: str) -> bool:
    """
    Ensure that a directory exists, creating it if necessary.
    Handles both local directories and GCS buckets.
    
    Args:
        directory: Directory path
        
    Returns:
        True if successful, False otherwise
    """
    try:
        # Handle GCS paths
        if directory.startswith('gs://'):
            # For GCS paths, we assume they exist or will be created when needed
            return True
        
        # Handle local directories
        os.makedirs(directory, exist_ok=True)
        return True
    except Exception as e:
        log_error(f"Failed to create directory {directory}: {e}")
        return False

def ensure_directories(directories: List[str]) -> bool:
    """
    Ensure that multiple directories exist, creating them if necessary.
    
    Args:
        directories: List of directory paths
        
    Returns:
        True if all successful, False otherwise
    """
    success = True
    for directory in directories:
        if not ensure_directory(directory):
            success = False
    return success

if __name__ == "__main__":
    # Simple test if this module is run directly
    config = get_config()
    print("Loaded configuration:", config) 