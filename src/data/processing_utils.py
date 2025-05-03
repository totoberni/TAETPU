"""
Shared utilities for data preprocessing.

This module provides common functionality used across different preprocessing
steps, including configuration loading, caching, parallel processing, and text cleaning.
"""

import os
import re
import json
import hashlib
import logging
import yaml
import torch
import time
import concurrent.futures
import numpy as np
from datetime import datetime, timedelta
from typing import Dict, List, Any, Callable, Tuple, Optional, Union, Iterator, Generator
from concurrent.futures import ProcessPoolExecutor
from tqdm import tqdm
from transformers import PreTrainedTokenizer
from sklearn.metrics import silhouette_score
from sklearn.cluster import KMeans
from itertools import islice

# Configure logger
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger('data_processing')

def setup_logger(name: str, level: int = logging.INFO) -> logging.Logger:
    """Create and configure a logger for a specific module."""
    new_logger = logging.getLogger(name)
    new_logger.setLevel(level)
    return new_logger

def load_config(config_path: str) -> Dict:
    """Load configuration from YAML file."""
    logger.info(f"Loading configuration from {config_path}")
    try:
        with open(config_path, 'r') as f:
            config = yaml.safe_load(f)
        logger.info("Configuration loaded successfully")
        return config
    except Exception as e:
        logger.error(f"Failed to load configuration: {e}")
        raise

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
    file_datetime = datetime.fromtimestamp(file_time)
    age = datetime.now() - file_datetime
    
    return age < timedelta(hours=max_age_hours)

def save_to_cache(data: Any, cache_path: str) -> None:
    """Save data to cache file."""
    try:
        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
        torch.save(data, cache_path)
        logger.info(f"Data cached successfully to {cache_path}")
    except Exception as e:
        logger.warning(f"Failed to cache data: {e}")

def load_from_cache(cache_path: str) -> Any:
    """Load data from disk cache."""
    if not os.path.exists(cache_path):
        raise FileNotFoundError(f"Cache file not found: {cache_path}")
        
    # Load based on file extension
    if cache_path.endswith('.npy'):
        return np.load(cache_path)
    elif cache_path.endswith('.pt'):
        return torch.load(cache_path)
    elif cache_path.endswith('.json'):
        with open(cache_path, 'r') as f:
            return json.load(f)
    else:
        # Default to torch.load
        return torch.load(cache_path)

def clean_text(text: str, config: Dict = None) -> str:
    """Clean text based on configuration settings."""
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
        # Replace numbers with spaces to separate words properly
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
    
    n_processes = config.get('n_processes', os.cpu_count())
    chunk_size = config.get('chunk_size', 10)
    desc = config.get('desc', 'Processing')
    
    # Use single process for small datasets
    if len(items) < chunk_size * 2 or n_processes <= 1:
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
        future_to_item = {executor.submit(process_fn, item): item for item in items}
        
        for future in tqdm(
            concurrent.futures.as_completed(future_to_item), 
            total=len(items), 
            desc=desc
        ):
            item = future_to_item[future]
            try:
                results.append(future.result())
            except Exception as e:
                if error_handler:
                    errors.append((item, e))
                logger.error(f"Error processing item: {e}")
    
    if error_handler and errors:
        error_handler(errors)
    
    return results

# Token Alignment Functions
def get_word_boundaries(tokens: List[str]) -> List[int]:
    """Determine word boundary indices for tokens."""
    word_boundaries = []
    current_word_idx = 0
    
    for token in tokens:
        # Skip special tokens
        if token.startswith('<') and token.endswith('>'):
            word_boundaries.append(-1)
            continue
        
        # Check if subword
        if token.startswith('##') or token.startswith('▁') or token.startswith('Ġ'):
            word_boundaries.append(current_word_idx)
        else:
            current_word_idx += 1
            word_boundaries.append(current_word_idx)
    
    return word_boundaries

def create_token_alignment_map(
    transformer_tokens: List[str],
    static_tokens: List[str],
    transformer_word_ids: List[int],
    original_text: str = None
) -> Dict[int, List[int]]:
    """Create alignment mapping between transformer and static tokenizations."""
    # Create mapping from word_id to transformer token positions
    word_to_transformer = {}
    
    for i, word_id in enumerate(transformer_word_ids):
        if word_id is not None:
            if word_id not in word_to_transformer:
                word_to_transformer[word_id] = []
            word_to_transformer[word_id].append(i)
    
    # Create mapping from static tokens to original words
    static_word_ids = []
    current_word = None
    
    for token in static_tokens:
        if token in ['<cls>', '<sep>', '<pad>', '<unk>', '<mask>']:
            static_word_ids.append(None)
        elif token.startswith('▁'):
            # New word in SentencePiece
            current_word = len(static_word_ids)
            static_word_ids.append(current_word)
        else:
            # Continuation of the current word
            static_word_ids.append(current_word)
    
    # Create transformer to static alignment map
    alignment_map = {}
    
    for word_id, transformer_positions in word_to_transformer.items():
        static_positions = [i for i, w_id in enumerate(static_word_ids) if w_id == word_id]
        
        for t_pos in transformer_positions:
            if t_pos not in alignment_map:
                alignment_map[t_pos] = []
            alignment_map[t_pos].extend(static_positions)
    
    return alignment_map

def transfer_labels(
    transformer_labels: np.ndarray,
    alignment_map: np.ndarray,
    default_value: int = 0
) -> np.ndarray:
    """Transfer labels from transformer to static tokens using alignment map."""
    static_labels = np.full(len(alignment_map), default_value, dtype=transformer_labels.dtype)
    
    for static_idx, trans_idx in enumerate(alignment_map):
        if trans_idx != -1:
            static_labels[static_idx] = transformer_labels[trans_idx]
    
    return static_labels

def verify_alignment(
    transformer_tokens: List[str],
    static_tokens: List[str],
    alignment_map: Dict[int, List[int]],
    original_text: str
) -> float:
    """Verify alignment quality between transformer and static tokenizations."""
    # Count successful alignments
    successful = 0
    total = 0
    
    for t_pos, s_positions in alignment_map.items():
        if t_pos >= len(transformer_tokens) or not s_positions:
            continue
            
        t_token = transformer_tokens[t_pos]
        
        # Skip special tokens
        if t_token in ['[CLS]', '[SEP]', '[PAD]', '[UNK]', '[MASK]']:
            continue
            
        # Check if any static token matches
        match_found = False
        
        for s_pos in s_positions:
            if s_pos >= len(static_tokens):
                continue
                
            s_token = static_tokens[s_pos]
            
            # Clean tokens for comparison (remove special markers)
            t_token_clean = t_token.replace('##', '').replace('Ġ', '').replace('▁', '')
            s_token_clean = s_token.replace('▁', '')
            
            if t_token_clean in s_token_clean or s_token_clean in t_token_clean:
                match_found = True
                break
                
        if match_found:
            successful += 1
            
        total += 1
    
    # Calculate quality score
    if total == 0:
        return 0.0
        
    return successful / total

# TPU and Batch Processing Functions
def create_tpu_optimized_dataset(
    examples: List[Dict[str, Any]],
    fields: List[str],
    batch_size: int
) -> Dict[str, np.ndarray]:
    """
    Create TPU-optimized dataset with static shapes.
    
    TPUs require fixed shapes, so this pads all sequences to the same length.
    
    Args:
        examples: List of examples
        fields: Fields to include in the dataset
        batch_size: Batch size for TPU processing
        
    Returns:
        Dictionary of arrays optimized for TPU
    """
    # Determine maximum lengths for each field
    max_lengths = {}
    for field in fields:
        if all(field in ex for ex in examples):
            max_lengths[field] = max(len(ex[field]) for ex in examples if isinstance(ex[field], (list, np.ndarray)))
    
    # Pad all sequences to fixed lengths
    result = {}
    for field in fields:
        if field not in max_lengths:
            continue
            
        # Initialize array with padding
        shape = (len(examples), max_lengths[field])
        dtype = np.int32  # Default dtype
        
        # Try to determine dtype from first example
        if field in examples[0]:
            if isinstance(examples[0][field], np.ndarray):
                dtype = examples[0][field].dtype
            elif isinstance(examples[0][field], list) and examples[0][field]:
                first_item = examples[0][field][0]
                if isinstance(first_item, bool):
                    dtype = np.bool_
                elif isinstance(first_item, float):
                    dtype = np.float32
                
        # Create padded array
        padded = np.zeros(shape, dtype=dtype)
        masks = np.zeros(shape, dtype=np.int32)
        
        for i, ex in enumerate(examples):
            if field in ex:
                seq = ex[field]
                if isinstance(seq, (list, np.ndarray)):
                    seq_len = min(len(seq), max_lengths[field])
                    padded[i, :seq_len] = seq[:seq_len]
                    masks[i, :seq_len] = 1
        
        # Store in result
        result[field] = padded
        result[f"{field}_mask"] = masks
    
    # Ensure batch size is a multiple of TPU batch size
    num_examples = len(examples)
    if num_examples % batch_size != 0:
        pad_size = batch_size - (num_examples % batch_size)
        logger.info(f"Padding dataset to multiple of batch size: {num_examples} -> {num_examples + pad_size}")
        
        # Pad each array to multiple of batch size
        for field in result:
            shape = list(result[field].shape)
            shape[0] = pad_size
            padding = np.zeros(shape, dtype=result[field].dtype)
            result[field] = np.concatenate([result[field], padding], axis=0)
    
    return result

def pad_sequences(
    sequences: List[np.ndarray],
    padding_value: int = 0,
    max_length: Optional[int] = None,
    padding: str = 'longest'  # 'longest', 'max_length', or 'fixed'
) -> Tuple[np.ndarray, np.ndarray]:
    """
    Pad sequences to the same length and create attention masks.
    
    Args:
        sequences: List of sequences to pad
        padding_value: Value to use for padding
        max_length: Maximum sequence length (if None, use longest sequence)
        padding: Padding strategy ('longest', 'max_length', or 'fixed')
        
    Returns:
        Tuple of (padded_sequences, attention_masks)
    """
    # Determine padding length
    if padding == 'longest' or max_length is None:
        pad_len = max(len(seq) for seq in sequences)
    else:
        pad_len = max_length
    
    # Initialize output arrays
    batch_size = len(sequences)
    padded_seqs = np.full((batch_size, pad_len), padding_value, dtype=sequences[0].dtype)
    attention_masks = np.zeros((batch_size, pad_len), dtype=np.int32)
    
    # Fill arrays with sequence data
    for i, seq in enumerate(sequences):
        seq_len = min(len(seq), pad_len)
        padded_seqs[i, :seq_len] = seq[:seq_len]
        attention_masks[i, :seq_len] = 1
    
    return padded_seqs, attention_masks

def collate_batch(
    batch: List[Dict[str, Any]],
    tensor_fields: List[str],
    padding_value: int = 0
) -> Dict[str, torch.Tensor]:
    """
    Collate a batch of examples into a single batch with padding.
    
    Args:
        batch: List of examples to collate
        tensor_fields: Names of fields to convert to tensors
        padding_value: Value to use for padding
        
    Returns:
        Dictionary of batched tensors
    """
    result = {}
    
    # Process each field
    for field in tensor_fields:
        # Skip if field doesn't exist in all examples
        if not all(field in example for example in batch):
            continue
            
        # Extract field values
        values = [example[field] for example in batch]
        
        # Handle different data types
        if isinstance(values[0], (int, float, bool)):
            # Scalar values - convert to tensor
            result[field] = torch.tensor(values)
        elif isinstance(values[0], (list, np.ndarray)):
            # Sequence values - pad and convert to tensor
            if isinstance(values[0], list):
                values = [np.array(v) for v in values]
                
            # Pad sequences
            padded, masks = pad_sequences(values, padding_value)
            
            # Convert to tensors
            result[field] = torch.tensor(padded)
            result[f"{field}_mask"] = torch.tensor(masks)
        else:
            # Other types - try to make tensors
            try:
                result[field] = torch.tensor(values)
            except:
                logger.warning(f"Could not convert field '{field}' to tensor")
    
    return result

def create_batch_generator(
    inputs: List[Any],
    batch_size: int,
    shuffle: bool = False,
    drop_last: bool = False
) -> Generator[List[Any], None, None]:
    """
    Create a generator that yields batches of inputs.
    
    Args:
        inputs: List of input examples
        batch_size: Size of each batch
        shuffle: Whether to shuffle inputs before batching
        drop_last: Whether to drop the last batch if it's smaller than batch_size
        
    Yields:
        Batches of inputs
    """
    indices = list(range(len(inputs)))
    
    if shuffle:
        np.random.shuffle(indices)
    
    # Generate batches
    for i in range(0, len(indices), batch_size):
        batch_indices = indices[i:i + batch_size]
        
        # Skip last batch if drop_last and batch is smaller than batch_size
        if drop_last and len(batch_indices) < batch_size:
            continue
            
        batch = [inputs[idx] for idx in batch_indices]
        yield batch

# Memory-efficient data processing
class LazyDataset:
    """Memory-efficient dataset that loads data on demand."""
    
    def __init__(self, data_loader: Callable, indices: Optional[List[int]] = None):
        """
        Initialize lazy dataset.
        
        Args:
            data_loader: Function that takes an index and returns an example
            indices: Optional list of indices to include in the dataset
        """
        self.data_loader = data_loader
        self.indices = indices or []
        
    def __len__(self) -> int:
        """Get dataset length."""
        return len(self.indices) if self.indices is not None else 0
        
    def __getitem__(self, idx: int) -> Any:
        """Get item at index."""
        if self.indices is not None:
            idx = self.indices[idx]
        return self.data_loader(idx)
        
    def iter_batches(self, batch_size: int, shuffle: bool = False) -> Iterator[List[Any]]:
        """Iterate over dataset in batches."""
        indices = self.indices if self.indices is not None else range(len(self))
        
        if shuffle:
            indices = list(indices)
            np.random.shuffle(indices)
        
        for i in range(0, len(indices), batch_size):
            batch_indices = indices[i:i + batch_size]
            batch = [self.data_loader(idx) for idx in batch_indices]
            yield batch

class ShardedDataIterator:
    """Iterator for efficiently processing data in shards."""
    
    def __init__(self, 
                 data_path: str, 
                 shard_size: int = 1000, 
                 preprocess_fn: Optional[Callable] = None,
                 filter_fn: Optional[Callable] = None):
        """
        Initialize sharded data iterator.
        
        Args:
            data_path: Path to data file
            shard_size: Number of examples per shard
            preprocess_fn: Function to preprocess examples
            filter_fn: Function to filter examples
        """
        self.data_path = data_path
        self.shard_size = shard_size
        self.preprocess_fn = preprocess_fn
        self.filter_fn = filter_fn
        
        # Get total example count (this should be implemented based on your data format)
        self.total_examples = self._count_examples()
        self.total_shards = (self.total_examples + shard_size - 1) // shard_size
        
    def _count_examples(self) -> int:
        """Count total examples in data file."""
        # This should be implemented based on your data format
        # For line-based formats, could count lines:
        with open(self.data_path, 'r') as f:
            return sum(1 for _ in f)
        
    def __iter__(self) -> Iterator[List[Any]]:
        """Iterate over data in shards."""
        with open(self.data_path, 'r') as f:
            while True:
                # Read a shard of data
                shard = list(islice(f, self.shard_size))
                if not shard:
                    break
                    
                # Preprocess examples
                if self.preprocess_fn:
                    shard = [self.preprocess_fn(example) for example in shard]
                    
                # Filter examples
                if self.filter_fn:
                    shard = [ex for ex in shard if self.filter_fn(ex)]
                    
                yield shard
                
    def iter_batches(self, batch_size: int) -> Iterator[List[Any]]:
        """Iterate over data in batches."""
        for shard in self:
            for i in range(0, len(shard), batch_size):
                yield shard[i:i + batch_size]

class TaskDispatcher:
    """Dispatcher for parallel task execution with different task types."""
    
    def __init__(self, n_processes: Optional[int] = None):
        """Initialize task dispatcher."""
        self.n_processes = n_processes or max(1, os.cpu_count() - 1)
        self.task_handlers = {}
    
    def register_task_handler(self, task_type: str, handler_fn: Callable) -> None:
        """Register a handler function for a specific task type."""
        self.task_handlers[task_type] = handler_fn
    
    def process_tasks(self, tasks: List[Dict], default_handler: Optional[Callable] = None) -> List:
        """Process tasks in parallel based on their type."""
        results = []
        
        # Group tasks by type
        task_groups = {}
        for task in tasks:
            task_type = task.get('type', 'default')
            if task_type not in task_groups:
                task_groups[task_type] = []
            task_groups[task_type].append(task)
        
        # Process each task group with appropriate handler
        for task_type, group_tasks in task_groups.items():
            handler = self.task_handlers.get(task_type, default_handler)
            
            if handler is None:
                logger.warning(f"No handler registered for task type: {task_type}")
                continue
                
            logger.info(f"Processing {len(group_tasks)} tasks of type '{task_type}'")
            
            # Process tasks in parallel
            processed_tasks = process_in_parallel(
                process_fn=handler,
                items=group_tasks,
                config={'n_processes': self.n_processes, 'desc': f"Processing {task_type}"}
            )
            
            results.extend(processed_tasks)
        
        return results

# Additional Token Processing Utilities
def get_special_token_info(tokenizer: Any) -> Dict[str, int]:
    """Get special token IDs from tokenizer."""
    special_tokens = {}
    
    # Try getting token IDs from attributes
    token_attrs = [
        ('pad_token_id', 'pad'),
        ('unk_token_id', 'unk'),
        ('cls_token_id', 'cls'),
        ('sep_token_id', 'sep'),
        ('mask_token_id', 'mask')
    ]
    
    for attr, name in token_attrs:
        if hasattr(tokenizer, attr):
            token_id = getattr(tokenizer, attr)
            if token_id is not None:
                special_tokens[name] = token_id
    
    # Fallback to vocabulary lookup
    token_names = {
        'pad': ['[PAD]', '<pad>'],
        'unk': ['[UNK]', '<unk>'],
        'cls': ['[CLS]', '<cls>'],
        'sep': ['[SEP]', '<sep>'],
        'mask': ['[MASK]', '<mask>']
    }
    
    for token_type, tokens in token_names.items():
        if token_type not in special_tokens:
            for token in tokens:
                if hasattr(tokenizer, 'vocab') and token in tokenizer.vocab:
                    special_tokens[token_type] = tokenizer.vocab[token]
                    break
    
    return special_tokens

def get_valid_sequence_mask(sequence: np.ndarray, invalid_ids: List[int]) -> np.ndarray:
    """Create a mask for valid token positions."""
    mask = np.ones_like(sequence, dtype=bool)
    for id in invalid_ids:
        mask = mask & (sequence != id)
    return mask

def create_attention_mask(input_ids: torch.Tensor, pad_token_id: int = 0) -> torch.Tensor:
    """Create attention mask from input IDs."""
    return (input_ids != pad_token_id).int()

def reconstruct_text(token_ids: np.ndarray, tokenizer: Any, skip_special_tokens: bool = True) -> List[str]:
    """Reconstruct original text from token IDs."""
    if isinstance(tokenizer, PreTrainedTokenizer):
        return tokenizer.batch_decode(token_ids, skip_special_tokens=skip_special_tokens)
    elif hasattr(tokenizer, 'decode'):
        return [tokenizer.decode(ids[ids != 0]) for ids in token_ids]
    else:
        raise ValueError("Unsupported tokenizer type")

def check_dataset_exists(dataset_name: str, data_dir: str) -> bool:
    """Check if dataset exists in the specified directory."""
    dataset_path = os.path.join(data_dir, dataset_name)
    return os.path.exists(dataset_path)

def load_dataset(dataset_name: str, raw_dir: str) -> Any:
    """Load dataset from disk, verifying it exists first."""
    from datasets import load_from_disk
    
    dataset_path = os.path.join(raw_dir, dataset_name)
    
    # Check if dataset exists
    if not check_dataset_exists(dataset_name, raw_dir):
        raise FileNotFoundError(f"Dataset '{dataset_name}' not found at {dataset_path}")
    
    logger.info(f"Loading dataset from {dataset_path}")
    return load_from_disk(dataset_path)