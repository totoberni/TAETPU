"""
Data preprocessing for transformer models.

This script handles tokenization, padding, and preparation of inputs for transformer models.
It leverages shared utilities from processing_utils.py and data structures from data_types.py.
"""

import os
import logging
from typing import Dict, List, Optional, Any, Tuple
import numpy as np
import torch
from transformers import AutoTokenizer
from tqdm import tqdm

# Import custom modules
from data_types import TransformerInput, TransformerTarget
import processing_utils as utils

# Setup logger
logger = utils.setup_logger('preprocess_transformer')

def initialize_tokenizer(tokenizer_config: Dict) -> AutoTokenizer:
    """Initialize tokenizer based on configuration."""
    model_name = tokenizer_config.get('pretrained_model_name_or_path')
    logger.info(f"Initializing tokenizer: {model_name}")
    
    try:
        tokenizer = AutoTokenizer.from_pretrained(model_name)
        # Verify special tokens match configuration
        special_tokens = tokenizer_config.get('special_tokens', {})
        for token_type, token_text in special_tokens.items():
            expected_token = getattr(tokenizer, f"{token_type}_token", None)
            if expected_token and expected_token != token_text:
                logger.warning(f"Special token mismatch for {token_type}: "
                              f"Expected {token_text}, got {expected_token}")
        return tokenizer
    except Exception as e:
        logger.error(f"Failed to initialize tokenizer: {e}")
        raise

def tokenize_batch(texts: List[str], tokenizer: AutoTokenizer, max_length: int) -> Dict[str, np.ndarray]:
    """Tokenize a batch of texts using the transformer tokenizer."""
    # Use tokenizer for batch processing
    encoding = tokenizer(
        texts,
        padding='max_length',
        truncation=True,
        max_length=max_length,
        return_tensors='np',
        return_special_tokens_mask=True,
        return_token_type_ids=True,
        return_attention_mask=True,
        add_special_tokens=True
    )
    
    # Extract word_ids if available (for token alignment)
    word_ids_list = []
    
    # Process each example to get word_ids
    for i, text in enumerate(texts):
        if hasattr(tokenizer, 'word_ids'):
            # Modern tokenizers have this method
            tokens = tokenizer(text, add_special_tokens=True)
            word_ids = [tokens.word_ids(i) for i in range(len(tokens['input_ids']))]
            
            # Pad to max_length
            if len(word_ids) < max_length:
                word_ids.extend([None] * (max_length - len(word_ids)))
            else:
                word_ids = word_ids[:max_length]
                
            word_ids_list.append(word_ids)
        else:
            # Fallback for tokenizers without word_ids method
            tokens = tokenizer.convert_ids_to_tokens(encoding['input_ids'][i])
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
            
            word_ids_list.append(current_word_ids)
    
    # Add word_ids to encoding results
    result = {
        'input_ids': encoding['input_ids'],
        'attention_mask': encoding['attention_mask'],
        'token_type_ids': encoding['token_type_ids'],
        'special_tokens_mask': encoding['special_tokens_mask'],
        'word_ids': word_ids_list
    }
    
    return result

def process_example(item: Dict[str, Any], config: Dict) -> Tuple[TransformerInput, TransformerTarget]:
    """Process a single example to create transformer input and target."""
    tokenizer = item['tokenizer']
    text = item['text']
    label = item.get('label')
    dataset_config = item['dataset_config']
    max_length = dataset_config.get('max_length', 128)
    
    # Clean text using shared utility
    preprocessing_config = dataset_config.get('preprocessing', {})
    clean_text = utils.clean_text(text, preprocessing_config)
    
    # Tokenize text
    tokenized = tokenize_batch([clean_text], tokenizer, max_length)
    
    # Create input
    transformer_input = TransformerInput(
        input_ids=tokenized['input_ids'][0],
        attention_mask=tokenized['attention_mask'][0],
        token_type_ids=tokenized['token_type_ids'][0],
        special_tokens_mask=tokenized['special_tokens_mask'][0],
        metadata={
            'original_text': clean_text,
            'original_length': len(clean_text.split()),
            'word_ids': tokenized['word_ids'][0]
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

def preprocess_transformer_dataset(
    dataset_name: str,
    data_config: Dict,
    output_dir: str,
    cache_dir: str = None,
    force: bool = False,
    use_cache: bool = True,
    n_processes: int = None
) -> Dict:
    """Preprocess a dataset for transformer models."""
    # Ensure output directory exists
    os.makedirs(output_dir, exist_ok=True)
    
    # Create dataset-specific output directory
    output_path = os.path.join(output_dir, f"{dataset_name}_transformer")
    if os.path.exists(output_path) and not force:
        logger.info(f"Processed dataset already exists at {output_path}. Use --force to overwrite.")
        
        # Try to load existing data if needed
        try:
            inputs_path = os.path.join(output_path, "inputs.pt")
            targets_path = os.path.join(output_path, "targets.pt")
            
            transformer_inputs = torch.load(inputs_path)
            transformer_targets = torch.load(targets_path)
            
            tokenizer_path = os.path.join(output_path, "tokenizer")
            tokenizer = AutoTokenizer.from_pretrained(tokenizer_path)
            
            # Return data for potential use in static preprocessing
            return {
                'clean_texts': [inp.metadata['original_text'] for inp in transformer_inputs],
                'tokenizer': tokenizer,
                'transformer_inputs': transformer_inputs,
                'transformer_targets': transformer_targets
            }
        except Exception as e:
            logger.warning(f"Failed to load existing processed data: {e}")
            logger.info("Will reprocess dataset.")
    
    # Check cache if enabled
    if cache_dir and use_cache:
        os.makedirs(cache_dir, exist_ok=True)
        config_hash = utils.hash_config(data_config['datasets'][dataset_name])
        cache_path = os.path.join(cache_dir, f"{dataset_name}_transformer_{config_hash}.pt")
        
        if utils.is_cache_valid(cache_path) and not force:
            logger.info(f"Loading cached data from {cache_path}")
            try:
                result = utils.load_from_cache(cache_path)
                
                # Save to output directory as well
                os.makedirs(output_path, exist_ok=True)
                
                # Save inputs and targets
                torch.save(result['transformer_inputs'], os.path.join(output_path, "inputs.pt"))
                torch.save(result['transformer_targets'], os.path.join(output_path, "targets.pt"))
                
                # Save tokenizer
                result['tokenizer'].save_pretrained(os.path.join(output_path, "tokenizer"))
                
                return result
            except Exception as e:
                logger.warning(f"Failed to load cache: {e}")
    
    # Load dataset configuration
    dataset_config = data_config['datasets'][dataset_name]
    text_column = dataset_config['text_column']
    label_column = dataset_config['label_column']
    
    # Initialize tokenizer
    tokenizer_config = data_config['tokenizers']['transformer']
    tokenizer = initialize_tokenizer(tokenizer_config)
    
    # Load dataset
    raw_dataset = utils.load_dataset(dataset_name, os.path.dirname(output_dir))
    
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
    
    if n_processes is None:
        n_processes = data_config.get('alignment', {}).get('parallel', {}).get('n_processes', 4)
    
    # Define error handler
    def error_handler(errors):
        for item, error in errors:
            logger.error(f"Failed to process example: {error}")
    
    # Process in parallel
    parallel_config = {
        'n_processes': n_processes,
        'chunk_size': data_config.get('alignment', {}).get('parallel', {}).get('chunk_size', 10),
        'desc': f"Processing {dataset_name}"
    }
    
    results = utils.process_in_parallel(
        process_fn=lambda item: process_example(item, dataset_config),
        items=items,
        config=parallel_config,
        error_handler=error_handler
    )
    
    # Unpack results
    inputs, targets = zip(*results)
    
    # Save processed data
    logger.info(f"Saving processed data to {output_path}")
    os.makedirs(output_path, exist_ok=True)
    
    # Save inputs and targets
    torch.save(inputs, os.path.join(output_path, "inputs.pt"))
    torch.save(targets, os.path.join(output_path, "targets.pt"))
    
    # Save tokenizer
    tokenizer.save_pretrained(os.path.join(output_path, "tokenizer"))
    
    # Prepare result dictionary
    result = {
        'clean_texts': [inp.metadata['original_text'] for inp in inputs],
        'original_texts': texts,
        'tokenizer': tokenizer,
        'transformer_inputs': inputs,
        'transformer_targets': targets
    }
    
    # Cache result if enabled
    if cache_dir and use_cache:
        logger.info(f"Caching processed data to {cache_path}")
        utils.save_to_cache(result, cache_path)
    
    logger.info(f"Dataset {dataset_name} processed successfully")
    return result