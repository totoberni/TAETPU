"""
data_utils.py - Shared utility functions for data operations.

This module provides common utilities used across data processing scripts, including
environment detection, path resolution, and environment variable handling.
"""
import os
import tempfile
from typing import Optional, Dict, Any, Union

def get_env_var(var_name: str, default: Any = None) -> Any:
    """Get environment variable or try to load it from .env file"""
    value = os.environ.get(var_name)
    if value is not None:
        return value
        
    # Try to load from .env file
    try:
        # Find project root from current file path
        current_dir = os.path.dirname(os.path.abspath(__file__))
        
        # Try multiple potential .env locations
        potential_env_paths = [
            # From project root
            os.path.abspath(os.path.join(current_dir, "..", "source", ".env")),
            # Docker path
            "/app/keys/env"
        ]
        
        for env_path in potential_env_paths:
            if os.path.exists(env_path):
                with open(env_path, 'r') as env_file:
                    for line in env_file:
                        if line.strip() and not line.startswith('#'):
                            key, val = line.strip().split('=', 1)
                            if key == var_name:
                                return val
                break
    except Exception as e:
        print(f"Warning: Error loading .env file: {e}")
    
    return default

def detect_environment() -> Dict[str, Any]:
    """
    Detect the current runtime environment and return appropriate paths and settings.
    
    Returns:
        dict: Environment information with the following keys:
            - environment: 'docker', 'tpu_vm', or 'local'
            - output_dir: Appropriate temporary directory for data
            - is_container: True if running in Docker container
    """
    # Check if we're in a Docker container
    if os.path.exists('/app/mount'):
        return {
            'environment': 'docker',
            'output_dir': tempfile.mkdtemp(prefix="docker_data_"),
            'is_container': True
        }
    
    # Check if we're directly on TPU VM
    if os.path.exists('/tmp/app/mount'):
        return {
            'environment': 'tpu_vm',
            'output_dir': tempfile.mkdtemp(prefix="tpu_data_"),
            'is_container': False
        }
    
    # We're likely on the local machine - use a temporary directory
    return {
        'environment': 'local',
        'output_dir': tempfile.mkdtemp(prefix="local_data_"),
        'is_container': False
    }

def get_project_dir() -> str:
    """Get the project root directory path"""
    current_dir = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(current_dir, ".."))

def get_default_config_path() -> str:
    """Get the default configuration path based on the environment"""
    project_dir = get_project_dir()
    
    # Try common locations in order of likelihood
    potential_paths = [
        # In the src/exp structure (default)
        os.path.join(project_dir, "src", "exp", "configs", "data_config.yaml"),
        
        # In dev/src/exp structure
        os.path.abspath(os.path.join(project_dir, "..", "dev", "src", "exp", "configs", "data_config.yaml")),
        
        # In Docker container
        "/app/src/exp/configs/data_config.yaml",
    ]
    
    # Return the first config file that exists
    for path in potential_paths:
        if os.path.isfile(path):
            return path
    
    # Return the first path as default even if it doesn't exist
    return potential_paths[0] 