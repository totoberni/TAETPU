"""
Utility functions for data preprocessing.

This module provides shared utilities for data preprocessing
with a focus on TPU compatibility and performance.
"""

from .processing import (
    load_config,
    hash_config,
    is_cache_valid,
    save_to_cache,
    load_from_cache,
    clean_text,
    process_in_parallel,
    optimize_for_tpu
)

from .data_io import (
    load_dataset,
    save_dataset
)

from .tpu_ops import (
    convert_to_bfloat16,
    create_length_buckets
) 