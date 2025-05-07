"""
Shared utilities for data preprocessing with TPU optimization.

This module provides essential functionality for data preprocessing
with a focus on TPU compatibility and performance.
"""

import os
import re
import json
import hashlib
import logging
import yaml
import torch
import time
import multiprocessing
import numpy as np
from typing import Dict, List, Any, Callable, Optional, Union, Tuple
from concurrent.futures import ProcessPoolExecutor
from tqdm import tqdm
from pathlib import Path

# Configure logger
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger('utils.processing')

def setup_logger(name: str, level: int = logging.INFO) -> logging.Logger:
    """Create and configure a logger for a specific module."""
    module_logger = logging.getLogger(name)
    module_logger.setLevel(level)
    return module_logger

def ensure_directories_exist(paths: List[str]) -> None:
    """Create directories if they don't exist."""
    for path in paths:
        os.makedirs(path, exist_ok=True)
        logger.info(f"Ensured directory exists: {path}")

def load_config(config_path: str) -> Dict:
    """Load configuration from YAML file."""
    try:
        with open(config_path, 'r') as f:
            config = yaml.safe_load(f)
        logger.info(f"Configuration loaded from {config_path}")
        return config
    except Exception as e:
        logger.error(f"Failed to load configuration: {e}")
        return {}

def hash_config(config: Dict) -> str:
    """Create a hash of configuration for cache identification."""
    config_str = json.dumps(config, sort_keys=True)
    return hashlib.md5(config_str.encode()).hexdigest()

def is_cache_valid(cache_path: str, max_age_hours: int = 72) -> bool:
    """Check if cache file exists and is not too old."""
    if not os.path.exists(cache_path):
        return False
    
    # Check file age
    file_time = os.path.getmtime(cache_path)
    age_hours = (time.time() - file_time) / 3600
    
    return age_hours < max_age_hours

def save_to_cache(data: Any, cache_path: str) -> None:
    """Save data to cache file."""
    try:
        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
        torch.save(data, cache_path)
        logger.info(f"Data cached to {cache_path}")
    except Exception as e:
        logger.warning(f"Failed to cache data: {e}")

def load_from_cache(cache_path: str) -> Any:
    """Load data from disk cache."""
    if not os.path.exists(cache_path):
        raise FileNotFoundError(f"Cache file not found: {cache_path}")
    
    try:
        return torch.load(cache_path)
    except Exception as e:
        logger.error(f"Failed to load cache: {e}")
        raise

def clean_text(text: str, config: Dict = None) -> str:
    """
    Clean text based on configuration settings.
    
    Args:
        text: Input text to clean
        config: Preprocessing configuration
        
    Returns:
        Cleaned text
    """
    if not text or not isinstance(text, str):
        return ""
    
    if not config:
        config = {}
    
    # Apply cleaning operations based on config
    result = text
    
    # Remove HTML if specified
    if config.get('remove_html', False):
        result = re.sub(r'<[^>]+>', ' ', result)
    
    # Normalize Unicode if specified
    if config.get('normalize_unicode', False):
        import unicodedata
        result = unicodedata.normalize('NFKC', result)
    
    # Handle numbers if specified
    if config.get('handle_numbers', False):
        result = re.sub(r'\d+', ' [NUM] ', result)
    
    # Remove extra whitespace
    result = re.sub(r'\s+', ' ', result).strip()
    
    return result

def process_in_parallel(
    process_fn: Callable, 
    items: List[Any], 
    config: Dict = None,
    error_handler: Callable = None
) -> List[Any]:
    """Process items in parallel using ProcessPoolExecutor."""
    if not config:
        config = {}
    
    n_processes = config.get('n_processes', min(8, multiprocessing.cpu_count()))
    chunk_size = config.get('chunk_size', 10)
    desc = config.get('desc', 'Processing')
    
    # Use single process for small datasets
    if len(items) < 20 or n_processes <= 1:
        logger.info(f"Processing {len(items)} items in a single process")
        results = []
        errors = []
        
        for item in tqdm(items, desc=desc):
            try:
                results.append(process_fn(item))
            except Exception as e:
                if error_handler:
                    errors.append((item, e))
                logger.error(f"Error processing item: {e}")
        
        if error_handler and errors:
            error_handler(errors)
        
        return results
    
    # Use multiple processes for larger datasets
    logger.info(f"Processing {len(items)} items with {n_processes} processes")
    results = []
    errors = []
    
    with ProcessPoolExecutor(max_workers=n_processes) as executor:
        futures = {executor.submit(process_fn, item): i for i, item in enumerate(items)}
        
        for future in tqdm(
            futures, 
            total=len(items), 
            desc=desc
        ):
            item_idx = futures[future]
            try:
                results.append(future.result())
            except Exception as e:
                if error_handler:
                    errors.append((items[item_idx], e))
                logger.error(f"Error processing item {item_idx}: {e}")
    
    if error_handler and errors:
        error_handler(errors)
    
    return results

def optimize_for_tpu(
    inputs: List[Any],
    targets: List[Any],
    output_dir: str,
    model_type: str,
    batch_size: int = 128
) -> None:
    """
    Create TPU-optimized dataset with static shapes.
    
    Args:
        inputs: List of input objects
        targets: List of target objects
        output_dir: Directory to save TPU-optimized arrays
        model_type: 'transformer' or 'static'
        batch_size: Batch size for TPU processing
    """
    os.makedirs(output_dir, exist_ok=True)
    
    # Extract fields based on model type
    if model_type == 'transformer':
        # Prepare input tensors
        input_arrays = {
            'input_ids': np.stack([x.input_ids for x in inputs]),
            'attention_mask': np.stack([x.attention_mask for x in inputs])
        }
        
        # Add token_type_ids if available
        if all(hasattr(x, 'token_type_ids') and x.token_type_ids is not None for x in inputs):
            input_arrays['token_type_ids'] = np.stack([x.token_type_ids for x in inputs])
        
        # Prepare target tensors
        target_arrays = {
            'labels': np.stack([x.labels for x in targets]),
            'label_mask': np.stack([x.attention_mask for x in targets])
        }
        
        # Add task-specific labels
        task_names = set()
        for target in targets:
            if hasattr(target, 'task_labels'):
                task_names.update(target.task_labels.keys())
        
        for task_name in task_names:
            # Collect all targets that have this task
            task_targets = [t for t in targets if hasattr(t, 'task_labels') and task_name in t.task_labels]
            
            if task_targets:
                # Determine array shape from the first example
                first_shape = task_targets[0].task_labels[task_name].labels.shape
                dtype = task_targets[0].task_labels[task_name].labels.dtype
                
                # Create arrays with padding for examples without this task
                task_labels = np.zeros((len(targets),) + first_shape, dtype=dtype)
                task_masks = np.zeros((len(targets),) + first_shape, dtype=np.int32)
                
                # Fill with actual values where available
                for i, target in enumerate(targets):
                    if hasattr(target, 'task_labels') and task_name in target.task_labels:
                        task_labels[i] = target.task_labels[task_name].labels
                        if target.task_labels[task_name].mask is not None:
                            task_masks[i] = target.task_labels[task_name].mask
                        else:
                            task_masks[i] = np.ones_like(target.task_labels[task_name].labels, dtype=np.int32)
                
                target_arrays[f'{task_name}_labels'] = task_labels
                target_arrays[f'{task_name}_mask'] = task_masks
    
    else:  # static
        # Prepare input tensors
        input_arrays = {
            'center_words': np.stack([x.center_words for x in inputs]),
            'context_words': np.stack([x.context_words for x in inputs]),
            'context_mask': np.stack([x.context_mask for x in inputs])
        }
        
        # Prepare target tensors
        target_arrays = {
            'target_values': np.stack([x.target_values for x in targets]),
            'target_mask': np.stack([x.target_mask for x in targets])
        }
        
        # Add task-specific labels (same logic as transformer)
        task_names = set()
        for target in targets:
            if hasattr(target, 'task_labels'):
                task_names.update(target.task_labels.keys())
        
        for task_name in task_names:
            task_targets = [t for t in targets if hasattr(t, 'task_labels') and task_name in t.task_labels]
            
            if task_targets:
                first_shape = task_targets[0].task_labels[task_name].labels.shape
                dtype = task_targets[0].task_labels[task_name].labels.dtype
                
                task_labels = np.zeros((len(targets),) + first_shape, dtype=dtype)
                task_masks = np.zeros((len(targets),) + first_shape, dtype=np.int32)
                
                for i, target in enumerate(targets):
                    if hasattr(target, 'task_labels') and task_name in target.task_labels:
                        task_labels[i] = target.task_labels[task_name].labels
                        if target.task_labels[task_name].mask is not None:
                            task_masks[i] = target.task_labels[task_name].mask
                        else:
                            task_masks[i] = np.ones_like(target.task_labels[task_name].labels, dtype=np.int32)
                
                target_arrays[f'{task_name}_labels'] = task_labels
                target_arrays[f'{task_name}_mask'] = task_masks
    
    # Combine all arrays
    all_arrays = {**input_arrays, **target_arrays}
    
    # Pad to multiple of batch size for TPU
    num_examples = len(inputs)
    remainder = num_examples % batch_size
    
    if remainder > 0:
        pad_size = batch_size - remainder
        logger.info(f"Padding dataset to multiple of batch size {batch_size}: {num_examples} -> {num_examples + pad_size}")
        
        # Pad each array
        for field, array in all_arrays.items():
            pad_shape = list(array.shape)
            pad_shape[0] = pad_size
            padding = np.zeros(pad_shape, dtype=array.dtype)
            all_arrays[field] = np.concatenate([array, padding], axis=0)
    
    # Save all arrays
    for field, array in all_arrays.items():
        array_path = os.path.join(output_dir, f"{field}.npy")
        np.save(array_path, array)
        logger.info(f"Saved TPU-optimized array: {field} with shape {array.shape}")
    
    # Save metadata
    metadata = {
        'model_type': model_type,
        'batch_size': batch_size,
        'original_examples': num_examples,
        'padded_examples': len(inputs) + (pad_size if remainder > 0 else 0),
        'arrays': list(all_arrays.keys()),
        'created_at': time.time()
    }
    
    with open(os.path.join(output_dir, 'metadata.json'), 'w') as f:
        json.dump(metadata, f, indent=2)
        
    logger.info(f"Created TPU-optimized dataset with {len(all_arrays)} arrays")

def pad_sequences(
    sequences: List[np.ndarray],
    pad_value: int = 0,
    max_length: Optional[int] = None,
    pad_to_multiple_of: int = 8  # TPU optimization
) -> Tuple[np.ndarray, np.ndarray]:
    """
    Pad sequences to the same length for TPU compatibility.
    
    Args:
        sequences: List of sequences to pad
        pad_value: Value to use for padding
        max_length: Maximum sequence length (if None, use longest sequence)
        pad_to_multiple_of: Pad length to be multiple of this value (TPU optimization)
        
    Returns:
        Tuple of (padded_sequences, attention_masks)
    """
    # Determine padding length
    if max_length is None:
        max_length = max(len(seq) for seq in sequences)
    
    # Pad to multiple of pad_to_multiple_of for TPU efficiency
    if max_length % pad_to_multiple_of != 0:
        max_length = ((max_length + pad_to_multiple_of - 1) // pad_to_multiple_of) * pad_to_multiple_of
    
    # Initialize output arrays
    batch_size = len(sequences)
    padded_seqs = np.full((batch_size, max_length), pad_value, dtype=sequences[0].dtype)
    attention_masks = np.zeros((batch_size, max_length), dtype=np.int32)
    
    # Fill arrays with sequence data
    for i, seq in enumerate(sequences):
        seq_len = min(len(seq), max_length)
        padded_seqs[i, :seq_len] = seq[:seq_len]
        attention_masks[i, :seq_len] = 1
    
    return padded_seqs, attention_masks 