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
    load_config,
    DATA_PATHS,
    create_standard_directories
)

# Import centralized cache functionality
from ..cache import (
    save_to_cache,
    load_from_cache,
    cache_exists,
    clear_cache
)

# Ensure data directories exist
def ensure_data_directories():
    """Ensure all data directories exist."""
    data_dirs = [
        DATA_PATHS['DATASET_RAW_DIR'],
        DATA_PATHS['DATASET_CLEAN_STATIC_DIR'],
        DATA_PATHS['DATASET_CLEAN_TRANSFORMER_DIR']
    ]
    for path in data_dirs:
        os.makedirs(path, exist_ok=True)
        logger.debug(f"Ensured directory exists: {path}")

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

# Import processing utilities (non-TPU specific)
from .utils.processing import (
    clean_text,
    process_in_parallel
)

# Import data I/O utilities
from .utils.data_io import (
    load_dataset, 
    save_dataset, 
    download_dataset,
    download_all_datasets,
    save_processed_dataset,
    load_processed_data,
    export_to_tfrecord,
    import_from_tfrecord
)

# Initialize data directories on import
ensure_data_directories()

# Pipeline entry point for direct execution
def run_pipeline():
    """Run the data pipeline with command-line arguments."""
    from .pipeline import main
    main()

# Centralized dataset management functions
def preprocess_dataset(dataset_name, model_type="all", optimize_tpu=True, force=False, cache_dir=None, n_processes=None, config=None):
    """
    Preprocess a dataset for specified model type with centralized logic.
    
    Args:
        dataset_name: Name of the dataset to process
        model_type: Model type ('transformer', 'static', or 'all')
        optimize_tpu: Whether to optimize for TPU
        force: Whether to force reprocessing
        cache_dir: Cache directory for intermediate results
        n_processes: Number of processes to use
        config: Custom config to use (or None to load default)
        
    Returns:
        Dictionary with processing results
    """
    from .pipeline import preprocess_datasets
    import argparse
    
    if config is None:
        config = load_config()
    
    args = argparse.Namespace(
        preprocess=True,
        model=model_type,
        dataset=dataset_name,
        optimize_for_tpu=optimize_tpu,
        force=force,
        disable_cache=cache_dir is None,
        cache_dir=cache_dir or DATA_PATHS['CACHE_PREP_DIR'],
        output_dir=os.path.dirname(DATA_PATHS['DATASET_CLEAN_STATIC_DIR']),
        raw_dir=DATA_PATHS['DATASET_RAW_DIR'],
        n_processes=n_processes,
        config=DATA_PATHS['CONFIG_PATH'],
        profile=False
    )
    
    preprocess_datasets(args, config)
    
    # Return results
    result = {}
    model_types = ["transformer", "static"] if model_type == "all" else [model_type]
    for model in model_types:
        dataset_dir = os.path.join(os.path.dirname(DATA_PATHS['DATASET_CLEAN_STATIC_DIR']), 
                                  model, dataset_name)
        if os.path.exists(dataset_dir):
            result[model] = dataset_dir
    
    return result

def download_datasets_wrapper(dataset_names=None, force=False, config=None):
    """
    Download datasets with centralized logic.
    
    Args:
        dataset_names: List of dataset names or None for all 
        force: Whether to force download even if dataset exists
        config: Custom config to use (or None to load default)
        
    Returns:
        True if successful, False if any failed
    """
    if config is None:
        config = load_config()
    
    # Filter datasets if names provided
    if dataset_names:
        original_datasets = config.get('datasets', {})
        filtered_datasets = {k: v for k, v in original_datasets.items() if k in dataset_names}
        config['datasets'] = filtered_datasets
    
    return download_all_datasets(config, DATA_PATHS['DATASET_RAW_DIR'], force)

def view_dataset(dataset_name, model_type="all", dataset_type="clean", examples=3, detailed=False):
    """
    View a dataset with centralized logic.
    
    Args:
        dataset_name: Name of the dataset to view
        model_type: Model type ('transformer', 'static', or 'all')  
        dataset_type: Dataset type ('raw', 'clean', or 'auto')
        examples: Number of examples to show
        detailed: Whether to show detailed information
    """
    from .pipeline import view_datasets
    import argparse
    
    config = load_config()
    
    args = argparse.Namespace(
        view=True,
        model=model_type,
        dataset=dataset_name,
        dataset_type=dataset_type,
        examples=examples,
        detailed=detailed,
        output_dir=os.path.dirname(DATA_PATHS['DATASET_CLEAN_STATIC_DIR']),
        raw_dir=DATA_PATHS['DATASET_RAW_DIR'],
        config=DATA_PATHS['CONFIG_PATH']
    )
    
    view_datasets(args, config)

# Expose subpackages and utilities
__all__ = [
    # Subpackages
    'processors',
    'tasks',
    'utils',
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
    'ensure_directories_exist',
    'save_to_cache',
    'load_from_cache',
    'cache_exists',
    'clear_cache'
]

if __name__ == "__main__":
    run_pipeline()