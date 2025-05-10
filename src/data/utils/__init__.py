"""
Utility functions for data preprocessing.

This module provides shared utilities for data preprocessing
with a focus on TPU compatibility and performance.
"""

# Import TPU utilities via relative import
from ...tpu import (
    # TPU utilities
    optimize_tensor_dimensions,
    optimize_for_tpu,
    get_tpu_device,
    is_tpu_available,
    get_optimal_batch_size,
    set_xla_environment_variables,
    convert_to_bfloat16,
    create_length_buckets,
    create_tpu_dataloader,
    pad_sequences
)

# Import data-specific processing utilities
from .processing import (
    clean_text,
    process_in_parallel
)

# Import I/O utilities
from .data_io import (
    load_dataset,
    save_dataset,
    download_dataset,
    download_all_datasets,
    load_processed_data,
    save_processed_dataset,
    export_to_tfrecord,
    import_from_tfrecord
)

# Re-export all utilities for backward compatibility
__all__ = [
    # Processing
    'clean_text',
    'process_in_parallel',
    
    # TPU operations
    'optimize_for_tpu',
    'pad_sequences',
    'convert_to_bfloat16',
    'create_length_buckets',
    'set_xla_environment_variables',
    'create_tpu_dataloader',
    'optimize_tensor_dimensions',
    'get_tpu_device',
    'is_tpu_available',
    'get_optimal_batch_size',
    
    # I/O
    'load_dataset',
    'save_dataset',
    'download_dataset',
    'download_all_datasets',
    'load_processed_data',
    'save_processed_dataset',
    'export_to_tfrecord',
    'import_from_tfrecord'
] 