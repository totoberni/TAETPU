"""
Classification task generators.

This module implements generators for classification tasks:
- Sentiment/emotion classification
"""

import logging
import numpy as np
import random
from typing import Dict, List, Optional, Any
from tqdm import tqdm

from .base import TaskGenerator

# Configure logger
logger = logging.getLogger('tasks.classification')

class SentimentGenerator(TaskGenerator):
    """Generator for Sentiment/Emotion classification task."""
    
    def __init__(self, config: Dict):
        super().__init__(config)
        self.num_labels = self.config.get('num_labels', 6)  # Default to 6 emotions
        self.preserve_original_labels = self.config.get('preserve_original_labels', True)
    
    def supports_model_type(self, model_type: str) -> bool:
        """Sentiment supports both transformer and static models."""
        return model_type in ['transformer', 'static']
    
    def generate_labels(self, inputs: List[Any], tokenizer: Any = None) -> List[Any]:
        """Generate sentiment/emotion labels."""
        logger.info(f"Generating sentiment/emotion labels")
        task_labels = []
        
        # Process each input
        for inp in tqdm(inputs, desc="Generating sentiment labels"):
            if not hasattr(inp, 'metadata'):
                task_labels.append(None)
                continue
            
            # Try to get original label from metadata
            original_label = None
            if hasattr(inp, 'metadata') and 'original_label' in inp.metadata:
                original_label = inp.metadata['original_label']
            
            # Create label
            if original_label is not None and self.preserve_original_labels:
                # Use original label if available
                label = original_label
            else:
                # Generate random label for testing
                label = random.randint(0, self.num_labels - 1)
            
            # Create single-element task labels array
            labels = np.array([label], dtype=np.int64)
            
            # Create TaskLabels object
            from ..types import TaskLabels
            task_labels.append(TaskLabels(
                labels=labels,
                mask=np.array([1]),  # Always attend to sentiment label
                metadata={
                    'num_labels': self.num_labels,
                    'original_label': original_label
                }
            ))
        
        return task_labels 