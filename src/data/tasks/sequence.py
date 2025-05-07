"""
Sequence labeling task generators for NER and POS tagging.

This module implements generators for sequence labeling tasks:
- NER (Named Entity Recognition)
- POS (Part-of-Speech tagging)
"""

import logging
import numpy as np
from typing import Dict, List, Optional, Any
from tqdm import tqdm

from .base import TaskGenerator

# Configure logger
logger = logging.getLogger('tasks.sequence')

class NERGenerator(TaskGenerator):
    """Generator for Named Entity Recognition task."""
    
    def __init__(self, config: Dict):
        super().__init__(config)
        self.model = self.config.get('model', 'en_core_web_lg')
        self.ner_labels = [
            'O',           # Outside of a named entity
            'B-PERSON',    # Beginning of person name
            'I-PERSON',    # Inside of person name
            'B-ORG',       # Beginning of organization
            'I-ORG',       # Inside of organization
            'B-LOC',       # Beginning of location
            'I-LOC',       # Inside of location
            'B-MISC',      # Beginning of miscellaneous entity
            'I-MISC'       # Inside of miscellaneous entity
        ]
        self.label_to_id = {label: i for i, label in enumerate(self.ner_labels)}
        self._load_spacy_model()
    
    def _load_spacy_model(self):
        """Load spaCy model for NER."""
        try:
            import spacy
            self.nlp = spacy.load(self.model)
            logger.info(f"Loaded spaCy model {self.model}")
        except ImportError:
            logger.error("spaCy is not installed. Install with 'pip install spacy'")
            raise
        except OSError:
            logger.error(f"spaCy model {self.model} not found. Install with 'python -m spacy download {self.model}'")
            raise
    
    def supports_model_type(self, model_type: str) -> bool:
        """NER supports both transformer and static models."""
        return model_type in ['transformer', 'static']
    
    def generate_labels(self, inputs: List[Any], tokenizer: Any = None) -> List[Any]:
        """Generate NER labels."""
        logger.info(f"Generating NER labels")
        task_labels = []
        
        # Process each input
        for inp in tqdm(inputs, desc="Generating NER labels"):
            if not hasattr(inp, 'metadata') or 'original_text' not in inp.metadata:
                task_labels.append(None)
                continue
            
            text = inp.metadata['original_text']
            
            # Process with spaCy
            doc = self.nlp(text)
            
            # Extract entities with BIO tagging
            entities = []
            i = 0
            for token in doc:
                if token.ent_type_:
                    # Entity token
                    if i == 0 or doc[i-1].ent_type_ != token.ent_type_:
                        # Beginning of entity
                        entities.append(f"B-{token.ent_type_}")
                    else:
                        # Inside of entity
                        entities.append(f"I-{token.ent_type_}")
                else:
                    # Outside token
                    entities.append("O")
                i += 1
            
            # Convert to token-level labels
            if hasattr(inp, 'input_ids'):
                # For transformer models
                token_labels = np.zeros(len(inp.input_ids), dtype=np.int64)
                
                # Map from original text to tokens
                if hasattr(inp, 'metadata') and 'word_ids' in inp.metadata:
                    word_ids = inp.metadata['word_ids']
                    
                    # Map entity labels to tokens
                    for i, word_idx in enumerate(word_ids):
                        if word_idx is not None and word_idx < len(entities):
                            # Get entity label
                            entity_label = entities[word_idx]
                            # Convert to ID
                            if entity_label in self.label_to_id:
                                token_labels[i] = self.label_to_id[entity_label]
                            else:
                                # Handle unknown labels
                                token_labels[i] = self.label_to_id['O']
                
                # Create mask for valid positions (non-special tokens)
                valid_mask = None
                if hasattr(inp, 'special_tokens_mask'):
                    valid_mask = ~inp.special_tokens_mask.astype(bool)
                elif hasattr(inp, 'attention_mask'):
                    valid_mask = inp.attention_mask.astype(bool)
                else:
                    valid_mask = np.ones_like(token_labels, dtype=bool)
            
            else:
                # For static models, use simple mapping
                token_labels = np.array([self.label_to_id.get(e, 0) for e in entities], dtype=np.int64)
                valid_mask = np.ones_like(token_labels, dtype=bool)
            
            # Create TaskLabels
            from ..types import TaskLabels
            task_labels.append(TaskLabels(
                labels=token_labels,
                mask=valid_mask,
                metadata={
                    'label_map': self.label_to_id,
                    'id_to_label': {i: l for l, i in self.label_to_id.items()}
                }
            ))
        
        return task_labels

class POSGenerator(TaskGenerator):
    """Generator for Part-of-Speech tagging task."""
    
    def __init__(self, config: Dict):
        super().__init__(config)
        self.model = self.config.get('model', 'en_core_web_lg')
        self._load_spacy_model()
    
    def _load_spacy_model(self):
        """Load spaCy model for POS tagging."""
        try:
            import spacy
            self.nlp = spacy.load(self.model)
            
            # Get universal POS tags
            self.pos_tags = sorted(set([token.pos_ for token in self.nlp("This is a sample sentence.")]))
            # Add padding tag
            self.pos_tags = ['PAD'] + self.pos_tags
            self.pos_to_id = {tag: i for i, tag in enumerate(self.pos_tags)}
            
            logger.info(f"Loaded spaCy model {self.model} with {len(self.pos_tags)} POS tags")
        except ImportError:
            logger.error("spaCy is not installed. Install with 'pip install spacy'")
            raise
        except OSError:
            logger.error(f"spaCy model {self.model} not found. Install with 'python -m spacy download {self.model}'")
            raise
    
    def supports_model_type(self, model_type: str) -> bool:
        """POS supports both transformer and static models."""
        return model_type in ['transformer', 'static']
    
    def generate_labels(self, inputs: List[Any], tokenizer: Any = None) -> List[Any]:
        """Generate POS tags."""
        logger.info(f"Generating POS labels")
        task_labels = []
        
        # Process each input
        for inp in tqdm(inputs, desc="Generating POS labels"):
            if not hasattr(inp, 'metadata') or 'original_text' not in inp.metadata:
                task_labels.append(None)
                continue
            
            text = inp.metadata['original_text']
            
            # Process with spaCy
            doc = self.nlp(text)
            
            # Extract POS tags
            pos_tags = [token.pos_ for token in doc]
            
            # Convert to token-level labels
            if hasattr(inp, 'input_ids'):
                # For transformer models
                token_labels = np.zeros(len(inp.input_ids), dtype=np.int64)
                
                # Map from original text to tokens
                if hasattr(inp, 'metadata') and 'word_ids' in inp.metadata:
                    word_ids = inp.metadata['word_ids']
                    
                    # Map POS tags to tokens
                    for i, word_idx in enumerate(word_ids):
                        if word_idx is not None and word_idx < len(pos_tags):
                            # Get POS tag
                            pos_tag = pos_tags[word_idx]
                            # Convert to ID
                            token_labels[i] = self.pos_to_id.get(pos_tag, 0)  # Default to PAD
                
                # Create mask for valid positions (non-special tokens)
                valid_mask = None
                if hasattr(inp, 'special_tokens_mask'):
                    valid_mask = ~inp.special_tokens_mask.astype(bool)
                elif hasattr(inp, 'attention_mask'):
                    valid_mask = inp.attention_mask.astype(bool)
                else:
                    valid_mask = np.ones_like(token_labels, dtype=bool)
            
            else:
                # For static models, use simple mapping
                token_labels = np.array([self.pos_to_id.get(p, 0) for p in pos_tags], dtype=np.int64)
                valid_mask = np.ones_like(token_labels, dtype=bool)
            
            # Create TaskLabels
            from ..types import TaskLabels
            task_labels.append(TaskLabels(
                labels=token_labels,
                mask=valid_mask,
                metadata={
                    'label_map': self.pos_to_id,
                    'id_to_label': {i: l for l, i in self.pos_to_id.items()}
                }
            ))
        
        return task_labels 