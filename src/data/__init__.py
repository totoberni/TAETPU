"""Transformer Ablation Experiment Data Processing Package.

This package provides data processing utilities with TPU optimization support
for transformer architecture experiments.
"""

import os
import logging
from pathlib import Path

# Configure logging
logger = logging.getLogger(__name__)

# Import functions from parent package with relative imports
from ..tpu import (
    # TPU utilities
    get_tpu_device,
    is_tpu_available,
    get_optimal_batch_size,
    optimize_tensor_dimensions,
    optimize_for_tpu,
    convert_to_bfloat16,
    create_length_buckets,
    create_tpu_dataloader,
    pad_sequences,
    TPU_ENV_VARS,
    initialize_tpu_environment,
    set_xla_environment_variables
)

from ..utils import (
    # Environment and configuration
    ensure_directories_exist
)

from ..configs import (
    load_config,
    DATA_PATHS
)

# Import centralized cache functionality
from ..cache import (
    save_to_cache,
    load_from_cache,
    cache_exists,
    clear_cache,
    is_cache_valid
)

# Import data types
from .types import (
    DatasetType, 
    ModelType, 
    TaskType,
    TransformerInput,
    TransformerTarget,
    StaticInput,
    StaticTarget,
    TaskLabels
)

# Import processing utilities from processors
from .processors.processing import (
    clean_text,
    process_in_parallel
)

# Import data I/O utilities
from .io import (
    load_dataset, 
    save_dataset, 
    download_dataset,
    download_all_datasets,
    save_processed_dataset,
    load_processed_data,
    export_to_tfrecord,
    import_from_tfrecord
)

# Import pipeline functions
from .pipeline import (
    preprocess_datasets,
    view_datasets,
    main as pipeline_main,
    preprocess_dataset,
    download_datasets_wrapper,
    view_dataset,
    ensure_data_directories
)

# Initialize data directories on import
ensure_data_directories()

# Pipeline entry point for direct execution
def run_pipeline():
    """Run the data pipeline with command-line arguments."""
    pipeline_main()

# Expose subpackages and utilities
__all__ = [
    # Subpackages
    'processors',
    'tasks',
    'types',
    
    # Data types
    'DatasetType',
    'ModelType',
    'TaskType',
    'TransformerInput',
    'TransformerTarget',
    'StaticInput',
    'StaticTarget',
    'TaskLabels',
    
    # Core functions  
    'run_pipeline',
    'preprocess_dataset',
    'download_datasets_wrapper',
    'view_dataset',
    'ensure_data_directories',
    
    # TPU utilities
    'optimize_for_tpu',
    'optimize_tensor_dimensions',
    'get_tpu_device',
    'is_tpu_available',
    'get_optimal_batch_size',
    'set_xla_environment_variables',
    'initialize_tpu_environment',
    'create_tpu_dataloader',
    'convert_to_bfloat16',
    'create_length_buckets',
    'pad_sequences',
    
    # Data I/O
    'load_dataset',
    'save_dataset',
    'download_dataset',
    'download_all_datasets',
    'save_processed_dataset',
    'load_processed_data',
    'export_to_tfrecord',
    'import_from_tfrecord',
    
    # Processing utilities
    'clean_text',
    'process_in_parallel',
    
    # Cache utilities
    'save_to_cache',
    'load_from_cache',
    'cache_exists',
    'clear_cache',
    'is_cache_valid',
    
    # Directory management
    'ensure_directories_exist'
]

if __name__ == "__main__":
    run_pipeline()