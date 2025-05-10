"""
Transformer Ablation Experiment on TPU (TAETPU) - Core Package.

This package provides utilities and environment management for running 
transformer architecture experiments on Google Cloud TPUs.
"""

import os
import logging

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger('taetpu')

# Import from configs module
from src.configs import (
    DATA_PATHS,
    load_config,
    parse_env_file,
    create_standard_directories
)

# Import from utils module
from src.utils import (
    ensure_directories_exist,
    handle_errors,
    safe_operation,
    hash_config,
    setup_logger,
    process_in_parallel
)

# Import from tpu module
from src.tpu import (
    TPU_ENV_VARS,
    tpu_env,
    initialize_tpu_environment,
    set_xla_environment_variables,
    get_tpu_device,
    is_tpu_available,
    optimize_tensor_dimensions,
    get_optimal_batch_size,
    pad_sequences,
    optimize_for_tpu,
    convert_to_bfloat16,
    create_length_buckets,
    create_tpu_dataloader
)

# Import from cache module
from src.cache import (
    save_to_cache,
    load_from_cache,
    cache_exists,
    clear_cache,
    is_cache_valid
)

# Import from models module
from src.models import (
    save_model,
    load_model,
    load_pretrained_model
)

# Package exports
__all__ = [
    # Configuration management
    'load_config',
    'parse_env_file',
    'DATA_PATHS',
    'create_standard_directories',
    'ensure_directories_exist',
    
    # Utility functions
    'hash_config',
    'setup_logger',
    'handle_errors',
    'safe_operation',
    'process_in_parallel',
    
    # Environment setup
    'initialize_tpu_environment',
    'set_xla_environment_variables',
    'TPU_ENV_VARS',
    'tpu_env',
    
    # TPU utilities
    'get_tpu_device',
    'is_tpu_available',
    'optimize_tensor_dimensions',
    'get_optimal_batch_size',
    'pad_sequences',
    'optimize_for_tpu',
    'convert_to_bfloat16',
    'create_length_buckets',
    'create_tpu_dataloader',
    
    # Cache utilities
    'save_to_cache',
    'load_from_cache',
    'cache_exists',
    'clear_cache',
    'is_cache_valid',
    
    # Model utilities
    'save_model',
    'load_model',
    'load_pretrained_model'
]