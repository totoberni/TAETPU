"""
config_loader.py - Centralized YAML configuration loader for data processing tasks.

This module provides utilities for loading the data configuration file and retrieving 
dataset information in a consistent manner across all data processing scripts.
"""
import os
import yaml
from typing import Dict, List, Optional, Any, Union

# Import shared utilities
from src.utils.data_utils import get_default_config_path

# Get the default path dynamically
DEFAULT_CONFIG_PATH = get_default_config_path()

def load_config(config_path: Optional[str] = None) -> Dict[str, Any]:
    """
    Load dataset configuration from YAML file.
    
    Args:
        config_path (str, optional): Path to the configuration YAML file.
            If not provided, searches in standard locations.
            
    Returns:
        dict: Configuration data as a dictionary
        
    Raises:
        FileNotFoundError: If the configuration file does not exist
        yaml.YAMLError: If the configuration file is not valid YAML
    """
    if config_path is None:
        config_path = DEFAULT_CONFIG_PATH
        
    # Check if the file exists
    if not os.path.isfile(config_path):
        raise FileNotFoundError(f"Configuration file not found at {config_path}")
        
    # Load the configuration
    with open(config_path, 'r') as f:
        try:
            config = yaml.safe_load(f)
            return config
        except yaml.YAMLError as e:
            raise yaml.YAMLError(f"Error parsing YAML configuration: {e}")

def get_datasets_config(config_path: Optional[str] = None) -> Dict[str, Any]:
    """
    Get the datasets section from the configuration file.
    
    Args:
        config_path (str, optional): Path to the configuration YAML file.
            
    Returns:
        dict: Datasets configuration data
    """
    config = load_config(config_path)
    datasets_config = config.get('datasets', {})
    return datasets_config

def get_dataset_keys(config_path: Optional[str] = None) -> List[str]:
    """
    Get a list of all dataset keys defined in the configuration.
    
    Args:
        config_path (str, optional): Path to the configuration YAML file.
            
    Returns:
        list: List of dataset keys
    """
    datasets_config = get_datasets_config(config_path)
    return list(datasets_config.keys())

def get_dataset_info(dataset_key: str, config_path: Optional[str] = None) -> Optional[Dict[str, Any]]:
    """
    Get information for a specific dataset by its key.
    
    Args:
        dataset_key (str): The key of the dataset to retrieve
        config_path (str, optional): Path to the configuration YAML file.
            
    Returns:
        dict or None: Dataset configuration or None if not found
    """
    datasets_config = get_datasets_config(config_path)
    return datasets_config.get(dataset_key)

def get_dataset_name(dataset_key: str, config_path: Optional[str] = None) -> Optional[str]:
    """
    Get the Hugging Face dataset name for a specific dataset key.
    
    Args:
        dataset_key (str): The key of the dataset to retrieve
        config_path (str, optional): Path to the configuration YAML file.
            
    Returns:
        str or None: Dataset name or None if not found
    """
    dataset_info = get_dataset_info(dataset_key, config_path)
    if dataset_info:
        return dataset_info.get('name')
    return None

def resolve_config_path(config_path: Optional[str] = None) -> str:
    """
    Resolve the configuration path to an absolute path.
    
    This function is useful for ensuring that relative paths work correctly
    regardless of which script is calling the function.
    
    Args:
        config_path (str, optional): Path to the configuration YAML file.
            
    Returns:
        str: Absolute path to the configuration file
    """
    if config_path is None:
        return os.path.abspath(DEFAULT_CONFIG_PATH)
        
    # If path is already absolute, return it
    if os.path.isabs(config_path):
        return config_path
        
    # If path is relative to the current working directory
    if os.path.isfile(config_path):
        return os.path.abspath(config_path)
        
    # Try to interpret path as relative to this file
    base_dir = os.path.dirname(__file__)
    resolved_path = os.path.abspath(os.path.join(base_dir, config_path))
    
    if os.path.isfile(resolved_path):
        return resolved_path
    
    # Return the original path, even though it might not exist
    return os.path.abspath(config_path) 