"""
TPU-specific optimization utilities.

This module provides specialized functions for optimizing data processing
for TPU hardware, including BFloat16 conversion and length bucketing.
"""

import numpy as np
import logging
import os
from typing import Dict, List, Any, Optional, Tuple, Union

# Configure logger
logger = logging.getLogger('utils.tpu_ops')

def convert_to_bfloat16(data: Dict[str, np.ndarray]) -> Dict[str, np.ndarray]:
    """
    Convert data to BFloat16 for optimal TPU performance.
    
    Args:
        data: Dictionary of arrays to convert
        
    Returns:
        Dictionary with arrays converted to BFloat16
    """
    try:
        # Try to import torch_xla for BFloat16 conversion
        try:
            import torch
            import torch_xla.core.xla_model as xm
            has_torch_xla = True
        except ImportError:
            has_torch_xla = False
            logger.warning("torch_xla not available, falling back to float16")
        
        converted_data = {}
        for key, array in data.items():
            if array.dtype in [np.float32, np.float64]:
                if has_torch_xla:
                    # Convert via PyTorch tensors
                    tensor = torch.tensor(array)
                    tensor = tensor.to(torch.bfloat16)
                    converted_data[key] = tensor.numpy()
                else:
                    # Fall back to float16
                    converted_data[key] = array.astype(np.float16)
            else:
                # Keep original dtype for non-float arrays
                converted_data[key] = array
                
        return converted_data
    
    except Exception as e:
        logger.error(f"Error converting to BFloat16: {e}")
        # Return original data if conversion fails
        return data

def create_length_buckets(
    sequences: List[Any],
    min_length: int = 8,
    max_length: int = 1024,
    num_buckets: int = 8,
    pad_to_multiple_of: int = 8
) -> Tuple[Dict[int, List[int]], List[int]]:
    """
    Create length-based buckets for efficient TPU processing.
    
    Args:
        sequences: List of sequences to bucket
        min_length: Minimum sequence length
        max_length: Maximum sequence length
        num_buckets: Number of buckets to create
        pad_to_multiple_of: Ensure bucket sizes are multiples of this value
        
    Returns:
        Tuple of (buckets, bucket_sizes) where:
        - buckets: Dictionary mapping bucket index to list of sequence indices
        - bucket_sizes: List of padded sequence lengths for each bucket
    """
    # Get sequence lengths
    sequence_lengths = []
    for i, seq in enumerate(sequences):
        if hasattr(seq, 'input_ids'):
            # For transformer sequences
            attention_mask = getattr(seq, 'attention_mask', None)
            if attention_mask is not None:
                length = attention_mask.sum()
            else:
                length = len(seq.input_ids)
        elif hasattr(seq, 'center_words'):
            # For static embedding sequences
            length = len(seq.center_words)
        else:
            # Fallback for other sequence types
            length = len(seq)
        
        sequence_lengths.append((i, length))
    
    # Create log-spaced bucket boundaries
    bucket_boundaries = np.logspace(
        np.log10(min_length),
        np.log10(max_length),
        num_buckets
    ).astype(np.int32)
    
    # Ensure boundaries are multiples of pad_to_multiple_of
    bucket_boundaries = [((b + pad_to_multiple_of - 1) // pad_to_multiple_of) * pad_to_multiple_of 
                        for b in bucket_boundaries]
    
    # Assign sequences to buckets
    buckets = {}
    for idx, length in sequence_lengths:
        # Find appropriate bucket
        bucket_idx = np.searchsorted(bucket_boundaries, length)
        if bucket_idx not in buckets:
            buckets[bucket_idx] = []
        buckets[bucket_idx].append(idx)
    
    # Determine actual bucket sizes (padded to multiple of pad_to_multiple_of)
    bucket_sizes = []
    for i in range(num_buckets):
        if i < len(bucket_boundaries):
            size = bucket_boundaries[i]
        else:
            size = max_length
        bucket_sizes.append(size)
    
    logger.info(f"Created {len(buckets)} length buckets with sizes: {bucket_sizes}")
    
    # Log bucket statistics
    for bucket_idx, indices in buckets.items():
        if bucket_idx < len(bucket_sizes):
            bucket_size = bucket_sizes[bucket_idx]
        else:
            bucket_size = max_length
        logger.info(f"Bucket {bucket_idx}: size={bucket_size}, examples={len(indices)}")
    
    return buckets, bucket_sizes

def set_xla_environment_variables() -> None:
    """
    Set TPU-specific environment variables for optimal performance.
    
    This should be called before importing any TPU-related libraries.
    """
    # Use BFloat16
    os.environ['XLA_USE_BF16'] = '1'
    
    # Optimize data loading
    os.environ['TF_ENABLE_EAGER_CLIENT_STREAMING_ENQUEUE'] = 'False'
    
    # Enable communication optimization
    os.environ['TPU_HBFB_SIZING_POLICY'] = 'AUTO_FAST'
    
    logger.info("Set TPU environment variables for optimal performance")

def create_tpu_dataloader(
    dataset: Any,
    batch_size: int = 128,
    is_training: bool = True
) -> Any:
    """
    Create a TPU-optimized data loader.
    
    Args:
        dataset: PyTorch Dataset
        batch_size: Batch size (should be multiple of 8)
        is_training: Whether to shuffle data for training
        
    Returns:
        TPU-optimized DataLoader
    """
    try:
        import torch
        import torch_xla.core.xla_model as xm
        import torch_xla.distributed.parallel_loader as pl
        from torch.utils.data import DataLoader, DistributedSampler
        
        # Ensure batch size is multiple of 8
        batch_size = ((batch_size + 7) // 8) * 8
        
        # Set up sampler for TPU
        sampler = torch.utils.data.distributed.DistributedSampler(
            dataset,
            num_replicas=xm.xrt_world_size(),
            rank=xm.get_ordinal(),
            shuffle=is_training
        )
        
        # Number of workers should be moderate to avoid excessive host memory usage
        num_workers = min(8, max(4, xm.xrt_world_size() // 2))
        
        # Create DataLoader with drop_last=True for consistent batches
        dataloader = DataLoader(
            dataset,
            batch_size=batch_size,
            sampler=sampler,
            num_workers=num_workers,
            drop_last=True,
            pin_memory=True
        )
        
        # Wrap with parallel loader for TPU
        device = xm.xla_device()
        dataloader = pl.MpDeviceLoader(dataloader, device)
        
        logger.info(f"Created TPU-optimized DataLoader with batch size {batch_size}")
        return dataloader
        
    except ImportError as e:
        logger.error(f"Failed to create TPU dataloader: {e}")
        logger.warning("Falling back to standard DataLoader")
        
        # Fallback to standard DataLoader
        from torch.utils.data import DataLoader
        return DataLoader(
            dataset,
            batch_size=batch_size,
            shuffle=is_training,
            num_workers=4,
            drop_last=True
        )
        
def optimize_for_tpu(inputs: List[Any], targets: List[Any], output_dir: str, 
                    model_type: str, batch_size: int = 128) -> None:
    """
    Create TPU-optimized dataset with static shapes.
    
    Args:
        inputs: List of input objects
        targets: List of target objects
        output_dir: Directory to save TPU-optimized arrays
        model_type: 'transformer' or 'static'
        batch_size: Batch size for TPU processing
    """
    import torch
    os.makedirs(output_dir, exist_ok=True)
    
    # Adjust batch size to multiple of 8 for TPU
    batch_size = ((batch_size + 7) // 8) * 8
    
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
    
    else:  # static embedding model
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
    
    # Convert to BFloat16 for better TPU performance
    all_arrays = convert_to_bfloat16(all_arrays)
    
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
        'created_at': torch.backends.cudnn.version() if hasattr(torch.backends.cudnn, 'version') else None
    }
    
    with open(os.path.join(output_dir, 'metadata.json'), 'w') as f:
        import json
        json.dump(metadata, f, indent=2)
        
    logger.info(f"Created TPU-optimized dataset with {len(all_arrays)} arrays") 