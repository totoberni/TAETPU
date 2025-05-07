"""
Transformer data processor with TPU optimization.

This module handles tokenization, padding, and preparation of inputs
for transformer models with a focus on TPU compatibility.
"""

import os
import logging
from typing import Dict, List, Optional, Any, Tuple, Union, Callable
import numpy as np
import torch
from tqdm import tqdm

# Import from package
from ..utils.processing import (
    hash_config, is_cache_valid, save_to_cache, load_from_cache, 
    clean_text, process_in_parallel, pad_sequences
)
from ..utils.data_io import load_dataset
from ..tasks import create_task_generator
from ..types import TransformerInput, TransformerTarget

# Setup logger
logger = logging.getLogger('processors.transformer')

class TokenizerProvider:
    """Base class for tokenizer providers."""
    
    def get_tokenizer(self, config: Dict) -> Any:
        """Get tokenizer based on configuration."""
        raise NotImplementedError("Subclasses must implement get_tokenizer")

class DefaultTokenizerProvider(TokenizerProvider):
    """Default implementation of tokenizer provider using HuggingFace."""
    
    def get_tokenizer(self, config: Dict) -> Any:
        """
        Get tokenizer from HuggingFace based on configuration.
        
        Args:
            config: Tokenizer configuration
            
        Returns:
            HuggingFace tokenizer
        """
        from transformers import AutoTokenizer
        
        model_name = config.get('pretrained_model_name_or_path')
        logger.info(f"Initializing tokenizer: {model_name}")
        
        try:
            tokenizer = AutoTokenizer.from_pretrained(model_name)
            # Verify special tokens match configuration
            special_tokens = config.get('special_tokens', {})
            for token_type, token_text in special_tokens.items():
                expected_token = getattr(tokenizer, f"{token_type}_token", None)
                if expected_token and expected_token != token_text:
                    logger.warning(f"Token mismatch for {token_type}: Expected {token_text}, got {expected_token}")
            return tokenizer
        except Exception as e:
            logger.error(f"Failed to initialize tokenizer: {e}")
            raise

class CacheManager:
    """Base class for cache managers."""
    
    def is_cached(self, cache_path: str) -> bool:
        """Check if cached data exists and is valid."""
        raise NotImplementedError("Subclasses must implement is_cached")
    
    def load(self, cache_path: str) -> Any:
        """Load data from cache."""
        raise NotImplementedError("Subclasses must implement load")
    
    def save(self, data: Any, cache_path: str) -> None:
        """Save data to cache."""
        raise NotImplementedError("Subclasses must implement save")

class DefaultCacheManager(CacheManager):
    """Default implementation of cache manager."""
    
    def is_cached(self, cache_path: str) -> bool:
        """
        Check if cached data exists and is valid.
        
        Args:
            cache_path: Path to cache file
            
        Returns:
            True if cache is valid, False otherwise
        """
        return is_cache_valid(cache_path)
    
    def load(self, cache_path: str) -> Any:
        """
        Load data from cache.
        
        Args:
            cache_path: Path to cache file
            
        Returns:
            Cached data
        """
        return load_from_cache(cache_path)
    
    def save(self, data: Any, cache_path: str) -> None:
        """
        Save data to cache.
        
        Args:
            data: Data to cache
            cache_path: Path to cache file
        """
        save_to_cache(data, cache_path)

class TransformerProcessor:
    """Processor for transformer model data with dependency injection."""
    
    def __init__(
        self,
        tokenizer_provider: Optional[TokenizerProvider] = None,
        cache_manager: Optional[CacheManager] = None
    ):
        """
        Initialize the transformer processor.
        
        Args:
            tokenizer_provider: Provider for tokenizers
            cache_manager: Manager for caching
        """
        self.tokenizer_provider = tokenizer_provider or DefaultTokenizerProvider()
        self.cache_manager = cache_manager or DefaultCacheManager()
    
    def tokenize_text(
        self, 
        texts: List[str], 
        tokenizer: Any, 
        max_length: int, 
        pad_to_multiple_of: int = 8
    ) -> Dict[str, np.ndarray]:
        """
        Tokenize a batch of texts with TPU optimization.
        
        Args:
            texts: List of text strings to tokenize
            tokenizer: HuggingFace tokenizer
            max_length: Maximum sequence length
            pad_to_multiple_of: Pad to multiple of this value for TPU efficiency
            
        Returns:
            Dictionary with tokenized outputs
        """
        # Pad to multiple of pad_to_multiple_of for TPU efficiency
        if max_length % pad_to_multiple_of != 0:
            pad_length = ((max_length + pad_to_multiple_of - 1) // pad_to_multiple_of) * pad_to_multiple_of
            logger.info(f"Adjusted max_length from {max_length} to {pad_length} for TPU compatibility")
            max_length = pad_length
        
        # Use tokenizer for batch processing with TPU-friendly padding
        encoding = tokenizer(
            texts,
            padding='max_length',
            truncation=True,
            max_length=max_length,
            return_tensors='np',
            return_special_tokens_mask=True,
            return_token_type_ids=True,
            return_attention_mask=True,
            add_special_tokens=True,
            pad_to_multiple_of=pad_to_multiple_of
        )
        
        # Process each example to get word_ids
        word_ids_list = []
        tokens_list = []
        
        for i, text in enumerate(texts):
            # Convert IDs to tokens
            tokens = tokenizer.convert_ids_to_tokens(encoding['input_ids'][i])
            tokens_list.append(tokens)
            
            # Extract word_ids (token to original word mapping)
            if hasattr(tokenizer, 'word_ids'):
                # Modern tokenizers have this method
                tokenized = tokenizer(text, add_special_tokens=True)
                word_ids = [tokenized.word_ids(0)[j] if j < len(tokenized.word_ids(0)) else None 
                           for j in range(max_length)]
                word_ids_list.append(word_ids)
            else:
                # Fallback for tokenizers without word_ids method
                word_id = -1
                current_word_ids = []
                
                for j, token in enumerate(tokens):
                    # Check if special token or continuation
                    if encoding['special_tokens_mask'][i][j]:
                        current_word_ids.append(None)
                    elif token.startswith('##') or token.startswith('Ġ') or token.startswith('▁'):
                        # Continuation of previous word
                        current_word_ids.append(word_id)
                    else:
                        # New word
                        word_id += 1
                        current_word_ids.append(word_id)
                
                # Pad to max_length
                if len(current_word_ids) < max_length:
                    current_word_ids.extend([None] * (max_length - len(current_word_ids)))
                
                word_ids_list.append(current_word_ids)
        
        return {
            'input_ids': encoding['input_ids'],
            'attention_mask': encoding['attention_mask'],
            'token_type_ids': encoding['token_type_ids'],
            'special_tokens_mask': encoding['special_tokens_mask'],
            'word_ids': word_ids_list,
            'tokens': tokens_list
        }
    
    def process_example(self, item: Dict[str, Any]) -> Tuple[TransformerInput, TransformerTarget]:
        """
        Process a single example to create transformer input and target.
        
        Args:
            item: Dictionary with example data
            
        Returns:
            Tuple of (TransformerInput, TransformerTarget)
        """
        tokenizer = item['tokenizer']
        text = item['text']
        label = item.get('label')
        dataset_config = item['dataset_config']
        max_length = dataset_config.get('max_length', 128)
        
        # Clean text using shared utility
        preprocessing_config = dataset_config.get('preprocessing', {})
        clean_text_str = clean_text(text, preprocessing_config)
        
        # Tokenize text
        tokenized = self.tokenize_text([clean_text_str], tokenizer, max_length)
        
        # Create input
        transformer_input = TransformerInput(
            input_ids=tokenized['input_ids'][0],
            attention_mask=tokenized['attention_mask'][0],
            token_type_ids=tokenized['token_type_ids'][0],
            special_tokens_mask=tokenized['special_tokens_mask'][0],
            metadata={
                'original_text': clean_text_str,
                'original_length': len(clean_text_str.split()),
                'word_ids': tokenized['word_ids'][0],
                'tokens': tokenized['tokens'][0]
            }
        )
        
        # Create target (basic version, task-specific labels will be added later)
        transformer_target = TransformerTarget(
            labels=tokenized['input_ids'][0].copy(),
            attention_mask=tokenized['attention_mask'][0]
        )
        
        # Add original label if available
        if label is not None:
            transformer_target.metadata = {'original_label': label}
        
        return transformer_input, transformer_target
    
    def process_dataset(
        self,
        dataset_name: str,
        config: Dict,
        output_dir: str,
        cache_dir: Optional[str] = None,
        force: bool = False,
        n_processes: Optional[int] = None
    ) -> Dict:
        """
        Preprocess a dataset for transformer models.
        
        Args:
            dataset_name: Name of the dataset to process
            config: Configuration dictionary
            output_dir: Directory to save processed data
            cache_dir: Directory for caching
            force: Whether to force reprocessing
            n_processes: Number of processes for parallel processing
            
        Returns:
            Dictionary with preprocessing results
        """
        # Ensure output directory exists
        os.makedirs(output_dir, exist_ok=True)
        
        # Create dataset-specific output directory
        dataset_dir = os.path.join(output_dir, dataset_name)
        if os.path.exists(dataset_dir) and not force:
            logger.info(f"Processed dataset already exists at {dataset_dir}. Use --force to overwrite.")
            
            # Try to load existing data
            try:
                inputs_path = os.path.join(dataset_dir, "inputs.pt")
                targets_path = os.path.join(dataset_dir, "targets.pt")
                
                transformer_inputs = torch.load(inputs_path)
                transformer_targets = torch.load(targets_path)
                
                # Load tokenizer
                tokenizer_path = os.path.join(dataset_dir, "tokenizer")
                from transformers import AutoTokenizer
                tokenizer = AutoTokenizer.from_pretrained(tokenizer_path)
                
                # Return data for potential use in static preprocessing
                return {
                    'clean_texts': [inp.metadata['original_text'] for inp in transformer_inputs],
                    'tokenizer': tokenizer,
                    'transformer_inputs': transformer_inputs,
                    'transformer_targets': transformer_targets
                }
            except Exception as e:
                logger.warning(f"Failed to load existing data: {e}")
                logger.info("Will reprocess dataset.")
        
        # Check cache if enabled
        if cache_dir:
            os.makedirs(cache_dir, exist_ok=True)
            config_hash = hash_config(config['datasets'][dataset_name])
            cache_path = os.path.join(cache_dir, f"{dataset_name}_transformer_{config_hash}.pt")
            
            if self.cache_manager.is_cached(cache_path) and not force:
                logger.info(f"Loading cached data from {cache_path}")
                try:
                    result = self.cache_manager.load(cache_path)
                    
                    # Save to output directory
                    os.makedirs(dataset_dir, exist_ok=True)
                    torch.save(result['transformer_inputs'], os.path.join(dataset_dir, "inputs.pt"))
                    torch.save(result['transformer_targets'], os.path.join(dataset_dir, "targets.pt"))
                    
                    # Save tokenizer
                    result['tokenizer'].save_pretrained(os.path.join(dataset_dir, "tokenizer"))
                    
                    # Generate task labels
                    self._generate_task_labels(
                        dataset_name=dataset_name,
                        inputs=result['transformer_inputs'],
                        config=config,
                        cache_dir=cache_dir,
                        output_dir=dataset_dir
                    )
                    
                    return result
                except Exception as e:
                    logger.warning(f"Failed to load cache: {e}")
        
        # Load dataset configuration
        dataset_config = config['datasets'][dataset_name]
        text_column = dataset_config['text_column']
        label_column = dataset_config['label_column']
        
        # Initialize tokenizer
        tokenizer_config = config['tokenizers']['transformer']
        tokenizer = self.tokenizer_provider.get_tokenizer(tokenizer_config)
        
        # Load dataset
        raw_dir = "/app/mount/src/datasets/raw"
        raw_dataset = load_dataset(dataset_name, os.path.dirname(raw_dir))
        
        # Get texts and labels
        texts = raw_dataset['unsplit'][text_column]
        labels = None
        if label_column and label_column in raw_dataset['unsplit'].column_names:
            labels = raw_dataset['unsplit'][label_column]
        
        # Prepare items for parallel processing
        items = []
        for i in range(len(texts)):
            item = {
                'tokenizer': tokenizer,
                'text': texts[i],
                'dataset_config': dataset_config
            }
            if labels is not None:
                item['label'] = labels[i]
            items.append(item)
        
        # Process examples in parallel
        logger.info(f"Processing {len(items)} examples for {dataset_name}")
        
        # Set default number of processes
        if n_processes is None:
            n_processes = config.get('alignment', {}).get('parallel', {}).get('n_processes', 4)
        
        # Error handler
        def error_handler(errors):
            for item, error in errors:
                logger.error(f"Failed to process example: {error}")
        
        # Process in parallel
        parallel_config = {
            'n_processes': n_processes,
            'chunk_size': config.get('alignment', {}).get('parallel', {}).get('chunk_size', 10),
            'desc': f"Processing {dataset_name}"
        }
        
        results = process_in_parallel(
            process_fn=self.process_example,
            items=items,
            config=parallel_config,
            error_handler=error_handler
        )
        
        # Unpack results
        inputs, targets = zip(*results)
        
        # Save processed data
        logger.info(f"Saving processed data to {dataset_dir}")
        os.makedirs(dataset_dir, exist_ok=True)
        
        torch.save(inputs, os.path.join(dataset_dir, "inputs.pt"))
        torch.save(targets, os.path.join(dataset_dir, "targets.pt"))
        
        # Save tokenizer
        tokenizer.save_pretrained(os.path.join(dataset_dir, "tokenizer"))
        
        # Prepare result dictionary
        result = {
            'clean_texts': [inp.metadata['original_text'] for inp in inputs],
            'tokenizer': tokenizer,
            'transformer_inputs': inputs,
            'transformer_targets': targets
        }
        
        # Cache result if enabled
        if cache_dir:
            logger.info(f"Caching processed data to {cache_path}")
            self.cache_manager.save(result, cache_path)
        
        # Generate task labels
        self._generate_task_labels(
            dataset_name=dataset_name,
            inputs=inputs,
            config=config,
            cache_dir=cache_dir,
            output_dir=dataset_dir
        )
        
        logger.info(f"Dataset {dataset_name} processed successfully with {len(inputs)} examples")
        return result
    
    def _generate_task_labels(
        self,
        dataset_name: str,
        inputs: List[TransformerInput],
        config: Dict,
        output_dir: str,
        cache_dir: Optional[str] = None
    ) -> None:
        """
        Generate task-specific labels for the dataset.
        
        Args:
            dataset_name: Name of the dataset
            inputs: List of transformer inputs
            config: Configuration dictionary
            output_dir: Output directory for the dataset
            cache_dir: Directory for caching
        """
        logger.info(f"Generating task labels for transformer dataset: {dataset_name}")
        
        # Load targets
        targets_path = os.path.join(output_dir, "targets.pt")
        targets = torch.load(targets_path)
        
        # Load tokenizer
        tokenizer_path = os.path.join(output_dir, "tokenizer")
        from transformers import AutoTokenizer
        tokenizer = AutoTokenizer.from_pretrained(tokenizer_path)
        
        # Get enabled tasks
        dataset_config = config['datasets'][dataset_name]
        enabled_tasks = dataset_config.get('enabled_tasks', [])
        
        if not enabled_tasks:
            logger.info(f"No tasks enabled for dataset {dataset_name}")
            return
        
        # Generate labels for each task
        all_task_labels = {}
        
        for task_name in enabled_tasks:
            # Get task-specific configuration
            task_config = {}
            
            # First get default configuration for this task type
            task_defaults = config.get('tasks', {}).get(task_name, {}).get('defaults', {})
            task_config.update(task_defaults)
            
            # Then apply dataset-specific overrides
            task_overrides = dataset_config.get('task_overrides', {}).get(task_name, {})
            task_config.update(task_overrides)
            
            # Create task generator
            generator = create_task_generator(task_name, task_config)
            
            if generator and generator.supports_model_type('transformer'):
                # Generate labels
                logger.info(f"Generating {task_name} labels for {dataset_name}")
                task_labels = generator.generate_labels(inputs, tokenizer)
                all_task_labels[task_name] = task_labels
            else:
                logger.info(f"Skipping {task_name} (not supported)")
        
        # Update targets with generated task labels
        for task_name, task_labels in all_task_labels.items():
            logger.info(f"Adding {task_name} labels to {len(targets)} targets")
            
            for i, (target, task_label) in enumerate(zip(targets, task_labels)):
                if task_label is not None:
                    target.task_labels[task_name] = task_label
        
        # Save updated targets
        torch.save(targets, targets_path)
        logger.info(f"Updated targets saved to {targets_path}") 