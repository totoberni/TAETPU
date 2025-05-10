"""
Data processing utilities for transformers and static embedding models.

This module provides core text processing and data transformation functions.
"""

import os
import re
import json
import logging
import yaml
import time
import numpy as np
from typing import Dict, List, Any, Callable, Optional, Union, Tuple
from pathlib import Path

# Import from parent packages
from ...utils import process_in_parallel, ensure_directories_exist, hash_config

# Configure logger
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger('data.processors.processing')

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

def create_alignment_map(transformer_inputs, static_vocabulary, clean_texts=None):
    """
    Creates mappings between transformer tokens and static word indices.
    
    Args:
        transformer_inputs: List of TransformerInput objects
        static_vocabulary: Dictionary mapping words to indices for static model
        clean_texts: Optional list of clean texts (if not provided, extracted from transformer_inputs)
        
    Returns:
        List of dictionaries mapping transformer token indices to static word indices
    """
    alignment_maps = []
    
    if clean_texts is None and transformer_inputs:
        clean_texts = [inp.metadata.get('original_text', '') for inp in transformer_inputs]
    
    for i, transformer_input in enumerate(transformer_inputs):
        # Get word_ids from transformer tokenization
        word_ids = transformer_input.metadata.get('word_ids')
        if not word_ids:
            alignment_maps.append(None)
            continue
            
        # Map transformer token indices to word indices
        token_to_word = {}
        for token_idx, word_idx in enumerate(word_ids):
            if word_idx is not None:  # Skip special tokens
                token_to_word[token_idx] = word_idx
                
        alignment_maps.append(token_to_word)
    
    return alignment_maps

def map_transformer_labels_to_static(transformer_labels, alignment_map, default_label=0):
    """
    Maps transformer token-level labels to static word-level labels.
    
    Args:
        transformer_labels: Labels at the transformer token level
        alignment_map: Mapping from transformer token indices to static word indices
        default_label: Default label to use for unmapped positions
        
    Returns:
        Array of labels at the static word level
    """
    if alignment_map is None:
        return None
        
    # Find the maximum static word index
    max_word_idx = max(alignment_map.values()) if alignment_map else -1
    if max_word_idx < 0:
        return None
        
    # Initialize static labels with default value
    static_labels = np.ones(max_word_idx + 1, dtype=transformer_labels.dtype) * default_label
    
    # Map transformer token labels to static word labels
    for token_idx, word_idx in alignment_map.items():
        if token_idx < len(transformer_labels):
            static_labels[word_idx] = transformer_labels[token_idx]
    
    return static_labels

def map_task_labels(transformer_task_labels, alignment_map, default_label=0):
    """
    Maps transformer TaskLabels to static TaskLabels using alignment mapping.
    
    Args:
        transformer_task_labels: TaskLabels object from transformer processing
        alignment_map: Mapping from transformer token indices to static word indices
        default_label: Default label value for unmapped positions
        
    Returns:
        New TaskLabels object for static model
    """
    from ..types import TaskLabels
    
    if transformer_task_labels is None or alignment_map is None:
        return None
    
    # Map the main labels
    static_labels = map_transformer_labels_to_static(
        transformer_task_labels.labels, 
        alignment_map, 
        default_label
    )
    
    if static_labels is None:
        return None
    
    # Create mask for mapped labels
    static_mask = np.ones_like(static_labels, dtype=np.int32)
    
    # Create static TaskLabels with mapped values
    static_task_labels = TaskLabels(
        labels=static_labels,
        mask=static_mask,
        metadata=transformer_task_labels.metadata.copy() if transformer_task_labels.metadata else {}
    )
    
    # Add alignment info to metadata
    static_task_labels.metadata['from_transformer_alignment'] = True
    
    return static_task_labels 