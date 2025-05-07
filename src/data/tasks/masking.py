"""
Masking task generators for masked language modeling.

This module implements generators for MLM (Masked Language Modeling)
and LMLM (Large span Masked Language Modeling) tasks.
"""

import logging
import numpy as np
import random
from typing import Dict, List, Optional, Any, Union, Tuple

# Import base classes
from .base import TaskGenerator

# Configure logger
logger = logging.getLogger('tasks.masking')

class MLMGenerator(TaskGenerator):
    """Generator for Masked Language Modeling task."""
    
    def __init__(self, config: Dict):
        super().__init__(config)
        self.mlm_probability = self.config.get('mlm_probability', 0.15)
        self.whole_word_mask = self.config.get('whole_word_mask', True)
    
    def supports_model_type(self, model_type: str) -> bool:
        """MLM supports both transformer and static models."""
        return model_type in ['transformer', 'static']
    
    def generate_labels(self, inputs: List[Any], tokenizer: Any = None) -> List[Any]:
        """Generate MLM labels for standard masked language modeling."""
        if not tokenizer:
            raise ValueError("Tokenizer is required for MLM task")
        
        logger.info(f"Generating MLM labels with probability {self.mlm_probability}")
        task_labels = []
        
        # Get mask token ID
        mask_token_id = tokenizer.convert_tokens_to_ids(tokenizer.mask_token)
        
        for inp in inputs:
            if not hasattr(inp, 'input_ids'):
                task_labels.append(None)
                continue
                
            input_ids = inp.input_ids
            attention_mask = inp.attention_mask
            
            # Get special tokens mask (1 for special tokens, 0 for normal tokens)
            special_tokens_mask = inp.special_tokens_mask if hasattr(inp, 'special_tokens_mask') else None
            if special_tokens_mask is None:
                special_tokens_ids = set([
                    tokenizer.cls_token_id, 
                    tokenizer.sep_token_id, 
                    tokenizer.pad_token_id
                ])
                special_tokens_mask = np.array([1 if id in special_tokens_ids else 0 
                                              for id in input_ids])
            
            # Copy input IDs
            masked_inputs = input_ids.copy()
            
            # Create labels initialized with -100 (ignored in loss calculation)
            labels = np.full_like(input_ids, -100)
            
            # Identify valid positions for masking (non-special tokens with attention)
            valid_positions = (special_tokens_mask == 0) & (attention_mask == 1)
            valid_indices = np.where(valid_positions)[0]
            
            # Skip if no valid positions
            if len(valid_indices) == 0:
                task_labels.append(TaskLabels(labels=labels, mask=valid_positions))
                continue
            
            # Apply whole word masking if enabled
            if self.whole_word_mask and hasattr(inp, 'metadata') and 'word_ids' in inp.metadata:
                word_ids = inp.metadata['word_ids']
                
                # Group indices by word ID
                word_groups = {}
                for i, word_id in enumerate(word_ids):
                    if word_id is not None and valid_positions[i]:
                        if word_id not in word_groups:
                            word_groups[word_id] = []
                        word_groups[word_id].append(i)
                
                # Calculate how many words to mask
                num_words = len(word_groups)
                num_to_mask = round(num_words * self.mlm_probability)
                num_to_mask = max(1, min(num_to_mask, num_words))
                
                # Randomly select words to mask
                words_to_mask = random.sample(list(word_groups.keys()), num_to_mask)
                
                # Mask all tokens for selected words
                for word_id in words_to_mask:
                    for idx in word_groups[word_id]:
                        # Set label to original token
                        labels[idx] = input_ids[idx]
                        
                        # 80% replace with [MASK]
                        if random.random() < 0.8:
                            masked_inputs[idx] = mask_token_id
                        # 10% replace with random token
                        elif random.random() < 0.5:
                            masked_inputs[idx] = random.randint(0, tokenizer.vocab_size - 1)
                        # 10% keep original (don't replace)
            else:
                # Token-level masking
                num_to_mask = round(len(valid_indices) * self.mlm_probability)
                num_to_mask = max(1, min(num_to_mask, len(valid_indices)))
                
                # Randomly select tokens to mask
                masking_indices = np.random.choice(valid_indices, num_to_mask, replace=False)
                
                # Create masking
                for idx in masking_indices:
                    # Set label to original token
                    labels[idx] = input_ids[idx]
                    
                    # 80% replace with [MASK]
                    if random.random() < 0.8:
                        masked_inputs[idx] = mask_token_id
                    # 10% replace with random token
                    elif random.random() < 0.5:
                        masked_inputs[idx] = random.randint(0, tokenizer.vocab_size - 1)
                    # 10% keep original (don't replace)
            
            # Create task labels from the TaskLabels class  
            from ..types import TaskLabels
            task_labels.append(TaskLabels(
                labels=labels,
                mask=valid_positions,
                metadata={
                    'masked_inputs': masked_inputs,
                    'mlm_probability': self.mlm_probability
                }
            ))
        
        return task_labels


class LMLMGenerator(TaskGenerator):
    """Generator for Large-span Masked Language Modeling."""
    
    def __init__(self, config: Dict):
        super().__init__(config)
        self.mask_probability = self.config.get('mask_probability', 0.15)
        self.min_span = self.config.get('min_span', 2)
        self.max_span = self.config.get('max_span', 5)
    
    def supports_model_type(self, model_type: str) -> bool:
        """LMLM supports transformer models."""
        return model_type == 'transformer'
    
    def generate_labels(self, inputs: List[Any], tokenizer: Any = None) -> List[Any]:
        """Generate LMLM labels for large span masked language modeling."""
        if not tokenizer:
            raise ValueError("Tokenizer is required for LMLM task")
        
        logger.info(f"Generating LMLM labels with spans {self.min_span}-{self.max_span}")
        task_labels = []
        
        # Get mask token ID
        mask_token_id = tokenizer.convert_tokens_to_ids(tokenizer.mask_token)
        
        for inp in inputs:
            if not hasattr(inp, 'input_ids'):
                task_labels.append(None)
                continue
                
            input_ids = inp.input_ids
            attention_mask = inp.attention_mask
            
            # Get special tokens mask
            special_tokens_mask = inp.special_tokens_mask if hasattr(inp, 'special_tokens_mask') else None
            if special_tokens_mask is None:
                special_tokens_ids = set([
                    tokenizer.cls_token_id, 
                    tokenizer.sep_token_id, 
                    tokenizer.pad_token_id
                ])
                special_tokens_mask = np.array([1 if id in special_tokens_ids else 0 
                                              for id in input_ids])
            
            # Copy input IDs
            masked_inputs = input_ids.copy()
            
            # Create labels initialized with -100 (ignored in loss calculation)
            labels = np.full_like(input_ids, -100)
            
            # Identify valid positions for masking (non-special tokens with attention)
            valid_positions = (special_tokens_mask == 0) & (attention_mask == 1)
            valid_indices = np.where(valid_positions)[0]
            
            # Skip if no valid positions
            if len(valid_indices) == 0:
                task_labels.append(TaskLabels(labels=labels, mask=valid_positions))
                continue
            
            # Calculate number of tokens to mask
            num_valid_tokens = len(valid_indices)
            num_to_mask = round(num_valid_tokens * self.mask_probability)
            num_to_mask = max(self.min_span, min(num_to_mask, num_valid_tokens))
            
            # Keep track of masked positions
            masked_positions = set()
            
            # Generate spans until we've masked enough tokens
            while len(masked_positions) < num_to_mask and len(masked_positions) < num_valid_tokens:
                # Skip if we have too few remaining tokens
                if num_valid_tokens - len(masked_positions) < self.min_span:
                    break
                
                # Determine span length with geometric distribution
                span_length = random.randint(self.min_span, self.max_span)
                span_length = min(span_length, num_to_mask - len(masked_positions))
                span_length = min(span_length, num_valid_tokens - len(masked_positions))
                
                # Select a starting position from remaining valid positions
                remaining_indices = [idx for idx in valid_indices if idx not in masked_positions]
                if not remaining_indices:
                    break
                
                # Prefer positions that create contiguous spans
                valid_starts = []
                for idx in remaining_indices:
                    # Check if we can create a valid span from this position
                    valid_span = True
                    for offset in range(span_length):
                        if (idx + offset) not in valid_indices or (idx + offset) in masked_positions:
                            valid_span = False
                            break
                    
                    if valid_span:
                        valid_starts.append(idx)
                
                if not valid_starts:
                    # If no valid contiguous spans, try again with smaller span
                    continue
                
                start_idx = random.choice(valid_starts)
                
                # Create the span
                for offset in range(span_length):
                    pos = start_idx + offset
                    # Set label to original token
                    labels[pos] = input_ids[pos]
                    # Replace with mask token
                    masked_inputs[pos] = mask_token_id
                    # Mark as masked
                    masked_positions.add(pos)
            
            # Create TaskLabels
            from ..types import TaskLabels
            task_labels.append(TaskLabels(
                labels=labels,
                mask=valid_positions,
                metadata={
                    'masked_inputs': masked_inputs,
                    'span_lengths': [self.min_span, self.max_span]
                }
            ))
        
        return task_labels 