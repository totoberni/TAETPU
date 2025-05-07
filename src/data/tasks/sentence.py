"""
Sentence-level task generators for discourse and coherence.

This module implements generators for sentence-level tasks:
- NSP (Next Sentence Prediction)
- Discourse Marker Prediction
"""

import logging
import numpy as np
import random
import re
from typing import Dict, List, Optional, Any
from tqdm import tqdm

from .base import TaskGenerator

# Configure logger
logger = logging.getLogger('tasks.sentence')

class NSPGenerator(TaskGenerator):
    """Generator for Next Sentence Prediction task."""
    
    def __init__(self, config: Dict):
        super().__init__(config)
        self.nsp_probability = self.config.get('nsp_probability', 0.5)
    
    def supports_model_type(self, model_type: str) -> bool:
        """NSP supports transformer models."""
        return model_type == 'transformer'
    
    def generate_labels(self, inputs: List[Any], tokenizer: Any = None) -> List[Any]:
        """Generate NSP labels for next sentence prediction."""
        if not tokenizer:
            logger.warning("Tokenizer is required for NSP task")
            return [None] * len(inputs)
        
        logger.info(f"Generating NSP labels")
        task_labels = []
        
        # Group texts to create sentence pairs
        texts = []
        for inp in inputs:
            if hasattr(inp, 'metadata') and 'original_text' in inp.metadata:
                texts.append(inp.metadata['original_text'])
        
        # Create positive and negative examples
        sentence_pattern = re.compile(r'(?<!\w\.\w.)(?<![A-Z][a-z]\.)(?<=\.|\?|\!)\s')
        
        # Extract sentences from texts
        all_sentences = []
        for text in texts:
            sentences = sentence_pattern.split(text)
            # Filter very short sentences
            valid_sentences = [s.strip() for s in sentences if len(s.split()) >= 3]
            all_sentences.extend(valid_sentences)
        
        # Skip if not enough sentences
        if len(all_sentences) < 10:
            logger.warning("Not enough sentences for NSP task")
            return [None] * len(inputs)
        
        # Create NSP labels (0: is next, 1: not next)
        rng = random.Random(42)  # Fixed seed for reproducibility
        
        for inp in tqdm(inputs, desc="Generating NSP labels"):
            # Create binary label (50% positive, 50% negative)
            is_positive = rng.random() < 0.5
            nsp_label = 0 if is_positive else 1
            
            # Create single-element task labels array
            labels = np.array([nsp_label], dtype=np.int64)
            
            # Create TaskLabels object
            from ..types import TaskLabels
            task_labels.append(TaskLabels(
                labels=labels,
                mask=np.array([1]),  # Always attend to NSP label
                metadata={
                    'is_next_sentence': is_positive
                }
            ))
        
        return task_labels

class DiscourseGenerator(TaskGenerator):
    """Generator for Discourse Marker Prediction task."""
    
    def __init__(self, config: Dict):
        super().__init__(config)
        # Get discourse markers from config
        self.markers = self.config.get('markers', [
            "However", "Therefore", "Moreover", "Nevertheless", "Consequently",
            "In addition", "On the other hand", "In contrast", "In summary",
            "In conclusion", "But", "As", "Further", "However,", "Nevertheless,"
        ])
        self.marker_to_id = {marker: i+1 for i, marker in enumerate(self.markers)}
        # Add special label for no marker
        self.marker_to_id['NONE'] = 0
    
    def supports_model_type(self, model_type: str) -> bool:
        """Discourse supports transformer models."""
        return model_type == 'transformer'
    
    def generate_labels(self, inputs: List[Any], tokenizer: Any = None) -> List[Any]:
        """Generate discourse marker labels."""
        logger.info(f"Generating discourse marker labels")
        task_labels = []
        
        # Process each input
        for inp in tqdm(inputs, desc="Generating discourse marker labels"):
            if not hasattr(inp, 'metadata') or 'original_text' not in inp.metadata:
                task_labels.append(None)
                continue
            
            text = inp.metadata['original_text']
            
            # Detect if any markers are present in the text
            found_markers = {}
            for marker in self.markers:
                # Find all occurrences of the marker
                start_idx = 0
                while True:
                    pos = text.find(marker, start_idx)
                    if pos == -1:
                        break
                    
                    # Check if it's really a marker (not part of another word)
                    if (pos == 0 or not text[pos-1].isalpha()) and \
                       (pos + len(marker) >= len(text) or not text[pos + len(marker)].isalpha()):
                        found_markers[pos] = marker
                    
                    start_idx = pos + 1
            
            # Create label
            if found_markers:
                # Use the most common marker if multiple are found
                marker = max(found_markers.values(), key=list(found_markers.values()).count)
                label = self.marker_to_id[marker]
            else:
                label = self.marker_to_id['NONE']
            
            # Create single-element task labels array
            labels = np.array([label], dtype=np.int64)
            
            # Create TaskLabels object
            from ..types import TaskLabels
            task_labels.append(TaskLabels(
                labels=labels,
                mask=np.array([1]),  # Always attend to discourse label
                metadata={
                    'marker_positions': found_markers,
                    'label_map': self.marker_to_id,
                    'id_to_label': {i: l for l, i in self.marker_to_id.items()}
                }
            ))
        
        return task_labels 