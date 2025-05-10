"""Configuration module for Transformer Ablation Experiment."""

import os
import logging
import yaml
import json
from pathlib import Path
from typing import Dict, Any, Optional, Union, List

# Configure logging
logger = logging.getLogger(__name__)

# Import shared utilities
from ..utils import safe_operation, ensure_directories_exist

# Define standard configuration paths
CONFIG_PATHS = {
    'DATA_CONFIG': os.path.join(os.path.dirname(__file__), 'data_config.yaml'),
    'MODEL_CONFIG': os.path.join(os.path.dirname(__file__), 'model_config.yaml'),
}

# Define standard data paths (moved from utils)
DATA_PATHS = {
    'CONFIG_PATH': '/app/mount/src/configs/data_config.yaml',
    'DATASET_RAW_DIR': '/app/mount/src/data/datasets/raw',
    'DATASET_CLEAN_STATIC_DIR': '/app/mount/src/data/datasets/clean/static',
    'DATASET_CLEAN_TRANSFORMER_DIR': '/app/mount/src/data/datasets/clean/transformer',
    'CACHE_PREP_DIR': '/app/mount/src/cache/prep',
    'MODELS_DIR': '/app/mount/src/models/saved',
    'MODELS_PREP_DIR': '/app/mount/src/models/prep',
}

class ConfigObject:
    """Base configuration object that provides attribute-style access to dict values."""
    
    def __init__(self, config_data: Dict[str, Any]):
        """
        Initialize config object with dictionary data.
        
        Args:
            config_data: Dictionary containing configuration values
        """
        self._data = config_data
        
        # Set attributes directly from config data
        for key, value in config_data.items():
            if isinstance(value, dict):
                setattr(self, key, ConfigObject(value))
            else:
                setattr(self, key, value)
    
    def __getitem__(self, key):
        """Allow dictionary-style access."""
        return self._data[key]
    
    def __contains__(self, key):
        """Check if key exists in config."""
        return key in self._data
    
    def get(self, key, default=None):
        """Get value with optional default, like dict.get()."""
        return self._data.get(key, default)
    
    def to_dict(self):
        """Convert back to dictionary."""
        return self._data
    
    def __repr__(self):
        """String representation of config object."""
        return f"ConfigObject({self._data})"

class DataConfig(ConfigObject):
    """Configuration object specifically for data processing."""
    
    @property
    def datasets(self):
        """Get dataset configurations."""
        return self.get('datasets', {})
    
    @property
    def processing(self):
        """Get processing configurations."""
        return self.get('processing', {})
    
    @property
    def cache_settings(self):
        """Get cache settings."""
        return self.get('cache', {})

class ModelConfig(ConfigObject):
    """Configuration object specifically for model settings."""
    
    @property
    def transformer_config(self):
        """Get transformer model configurations."""
        return self.get('transformer', {})
    
    @property
    def static_config(self):
        """Get static embedding model configurations."""
        return self.get('static', {})
    
    @property
    def training_config(self):
        """Get training configurations."""
        return self.get('training', {})

def parse_env_file(env_file_path: Optional[str] = None) -> Dict[str, str]:
    """
    Parse .env file and return variables as dictionary.
    
    Args:
        env_file_path: Path to .env file
        
    Returns:
        Dictionary with environment variables
    """
    if not env_file_path:
        # Try to find .env in standard locations
        possible_paths = [
            os.path.join(os.getcwd(), '.env'),
            os.path.join(os.getcwd(), 'config', '.env'),
            os.path.join(os.path.dirname(os.getcwd()), 'config', '.env'),
            '/app/mount/config/.env'
        ]
        
        for path in possible_paths:
            if os.path.exists(path):
                env_file_path = path
                break
    
    if not env_file_path or not os.path.exists(env_file_path):
        logger.warning(f"No .env file found")
        return {}
    
    env_vars = {}
    try:
        with open(env_file_path, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                
                if '=' in line:
                    key, value = line.split('=', 1)
                    key = key.strip()
                    value = value.strip()
                    
                    # Remove quotes if present
                    if (value.startswith('"') and value.endswith('"')) or \
                       (value.startswith("'") and value.endswith("'")):
                        value = value[1:-1]
                    
                    env_vars[key] = value
        
        logger.info(f"Loaded environment variables from {env_file_path}")
        return env_vars
    except Exception as e:
        logger.error(f"Error parsing .env file {env_file_path}: {e}")
        return {}

@safe_operation("config loading", default_return={})
def load_config(config_file_path: Optional[str] = None, env_file_path: Optional[str] = None) -> Dict[str, Any]:
    """
    Load configuration from YAML file and merge with .env variables.
    
    Args:
        config_file_path: Path to YAML config file
        env_file_path: Path to .env file
        
    Returns:
        Merged configuration dictionary
    """
    config = {}
    
    # Use default config path if not provided
    if not config_file_path:
        config_file_path = DATA_PATHS['CONFIG_PATH']
    
    # Load YAML configuration if provided
    if os.path.exists(config_file_path):
        with open(config_file_path, 'r') as f:
            config = yaml.safe_load(f) or {}
        logger.info(f"Configuration loaded from {config_file_path}")
    
    # Load and merge .env variables
    env_config = parse_env_file(env_file_path)
    
    # Update YAML config with .env values
    if 'datasets' not in config:
        config['datasets'] = {}
    
    # Process environment variables for datasets
    for key, value in env_config.items():
        if key.startswith('DATASET_') and '_NAME' in key:
            dataset_key = key.split('_NAME')[0][8:].lower()  # Remove DATASET_ prefix and _NAME suffix
            if dataset_key not in config['datasets']:
                config['datasets'][dataset_key] = {}
            config['datasets'][dataset_key]['name'] = value
            
    return config

@safe_operation("data config loading", default_return=None)
def get_data_config() -> Optional[DataConfig]:
    """
    Load data configuration from standard location.
    
    Returns:
        DataConfig object with configuration values or None if loading failed
    """
    config_dict = load_config(CONFIG_PATHS['DATA_CONFIG'])
    return DataConfig(config_dict)

@safe_operation("model config loading", default_return=None)
def get_model_config() -> Optional[ModelConfig]:
    """
    Load model configuration from standard location.
    
    Returns:
        ModelConfig object with configuration values or None if loading failed
    """
    config_dict = load_config(CONFIG_PATHS['MODEL_CONFIG'])
    return ModelConfig(config_dict)

@safe_operation("config merging", default_return={})
def merge_configs(*configs) -> Dict[str, Any]:
    """
    Merge multiple configuration dictionaries.
    
    Args:
        *configs: Configuration dictionaries to merge
        
    Returns:
        Merged configuration dictionary
    """
    result: Dict[str, Any] = {}
    for config in configs:
        if isinstance(config, ConfigObject):
            config = config.to_dict()
        if config:
            result.update(config)
    return result

@safe_operation("config saving", default_return=False)
def save_config(config: Union[Dict[str, Any], ConfigObject], config_file_path: str) -> bool:
    """
    Save configuration to a YAML file.
    
    Args:
        config: Configuration dictionary or ConfigObject
        config_file_path: Path to save the configuration
        
    Returns:
        True if successful, False otherwise
    """
    if isinstance(config, ConfigObject):
        config = config.to_dict()
        
    with open(config_file_path, 'w') as f:
        yaml.dump(config, f, default_flow_style=False)
    logger.info(f"Configuration saved to {config_file_path}")
    return True

def create_standard_directories() -> None:
    """Create standard directory structure if not exists."""
    for path in DATA_PATHS.values():
        try:
            ensure_directories_exist([path])
            logger.debug(f"Ensuring directory exists: {path}")
        except Exception as e:
            logger.error(f"Failed to create directory {path}: {e}")

# Initialize directories on module import
create_standard_directories()

__all__ = [
    'get_data_config',
    'get_model_config',
    'load_config',
    'parse_env_file',
    'CONFIG_PATHS',
    'DATA_PATHS',
    'ConfigObject',
    'DataConfig',
    'ModelConfig',
    'merge_configs',
    'save_config',
    'create_standard_directories'
]