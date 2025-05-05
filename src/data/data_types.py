"""
Data types for transformer and static embedding models.

This module defines the core data structures used for representing inputs and targets
for both transformer-based contextual embedding models and static embedding models.
These structures are optimized to support various NLP tasks including masked language
modeling, named entity recognition, part-of-speech tagging, and contrastive learning.
"""

from dataclasses import dataclass, field
from typing import Dict, Optional, Union, List, Tuple, Any
from enum import Enum, auto
import numpy as np
import torch


class TaskType(Enum):
    """Enumeration of supported NLP tasks."""
    MLM = auto()         # Masked Language Modeling (short spans)
    LMLM = auto()        # Large Masked Language Modeling (longer spans)
    NSP = auto()         # Next Sentence Prediction
    SENTIMENT = auto()   # Sentiment/Emotion Analysis
    NER = auto()         # Named Entity Recognition
    POS = auto()         # Part-of-Speech Tagging
    DISCOURSE = auto()   # Discourse Marker Prediction
    CONTRASTIVE = auto() # Contrastive Learning


@dataclass
class TaskLabels:
    """Container for task-specific labels and metadata.
    
    Attributes:
        labels: The primary label data for the task
        mask: Optional mask indicating which positions have valid labels
        metadata: Optional additional information related to the task
    """
    labels: np.ndarray
    mask: Optional[np.ndarray] = None
    metadata: Optional[Dict[str, Any]] = None


@dataclass
class BaseInput:
    """Base class for model inputs with shared functionality.
    
    Attributes:
        metadata: Optional metadata associated with the input
    """
    # Move metadata to a separate field class to avoid inheritance ordering issues
    # metadata: Optional[Dict[str, Any]] = None
    
    def to_tensors(self, device=None) -> Dict[str, torch.Tensor]:
        """Convert numpy arrays to PyTorch tensors.
        
        Args:
            device: Optional device to place tensors on
            
        Returns:
            Dictionary of PyTorch tensors
        """
        raise NotImplementedError("Subclasses must implement to_tensors")


@dataclass
class BaseTarget:
    """Base class for model targets with shared functionality.
    
    Attributes:
        task_labels: Dictionary mapping task names to their labels
        metadata: Optional metadata associated with the target
    """
    # Move task_labels and metadata to separate classes to avoid inheritance ordering issues
    # task_labels: Dict[str, TaskLabels] = field(default_factory=dict)
    # metadata: Optional[Dict[str, Any]] = None
    
    def to_tensors(self, device=None) -> Dict[str, torch.Tensor]:
        """Convert numpy arrays to PyTorch tensors.
        
        Args:
            device: Optional device to place tensors on
            
        Returns:
            Dictionary of PyTorch tensors
        """
        raise NotImplementedError("Subclasses must implement to_tensors")
    
    def add_task_labels(
        self,
        task_name: str,
        labels: np.ndarray,
        mask: Optional[np.ndarray] = None,
        metadata: Optional[Dict[str, Any]] = None
    ):
        """Add task-specific labels with metadata.
        
        Args:
            task_name: Name of the task
            labels: Label data for the task
            mask: Optional mask indicating which positions have valid labels
            metadata: Optional additional information related to the task
        """
        if not hasattr(self, 'task_labels'):
            self.task_labels = {}
            
        self.task_labels[task_name] = TaskLabels(
            labels=labels,
            mask=mask,
            metadata=metadata
        )


@dataclass
class TransformerInput(BaseInput):
    """Input container optimized for transformer/contextual embedding models.
    
    Attributes:
        input_ids: Token IDs of the input sequence
        attention_mask: Mask indicating which positions should be attended to (1) vs. ignored (0)
        token_type_ids: Optional IDs indicating which sequence a token belongs to (for NSP, etc.)
        position_ids: Optional explicit position IDs for each token
        special_tokens_mask: Optional mask identifying special tokens (CLS, SEP, etc.)
        mlm_mask: Optional mask for MLM training indicating which tokens are masked
        metadata: Optional additional metadata
    """
    input_ids: np.ndarray
    attention_mask: np.ndarray
    token_type_ids: Optional[np.ndarray] = None
    position_ids: Optional[np.ndarray] = None
    special_tokens_mask: Optional[np.ndarray] = None
    mlm_mask: Optional[np.ndarray] = None
    metadata: Optional[Dict[str, Any]] = None  # Add back explicitly at the end
    
    def to_tensors(self, device=None) -> Dict[str, torch.Tensor]:
        """Convert numpy arrays to PyTorch tensors.
        
        Args:
            device: Optional device to place tensors on
            
        Returns:
            Dictionary of PyTorch tensors
        """
        tensors = {
            'input_ids': torch.tensor(self.input_ids, dtype=torch.long),
            'attention_mask': torch.tensor(self.attention_mask, dtype=torch.long)
        }
        
        optional_tensors = {
            'token_type_ids': self.token_type_ids,
            'position_ids': self.position_ids,
            'special_tokens_mask': self.special_tokens_mask,
            'mlm_mask': self.mlm_mask
        }
        
        tensors.update({
            key: torch.tensor(value, dtype=torch.long)
            for key, value in optional_tensors.items()
            if value is not None
        })
        
        # Move tensors to specified device if provided
        if device is not None:
            tensors = {k: v.to(device) for k, v in tensors.items()}
        
        return tensors


@dataclass
class TransformerTarget(BaseTarget):
    """Target container optimized for transformer/contextual embedding models.
    
    Attributes:
        labels: Primary labels for the main task (often token IDs for MLM)
        attention_mask: Mask indicating which positions have valid labels
        task_labels: Dictionary of task-specific labels
        metadata: Optional additional metadata
    """
    labels: np.ndarray
    attention_mask: np.ndarray
    task_labels: Dict[str, TaskLabels] = field(default_factory=dict)  # Add back explicitly at the end
    metadata: Optional[Dict[str, Any]] = None  # Add back explicitly at the end
    
    def to_tensors(self, device=None) -> Dict[str, torch.Tensor]:
        """Convert numpy arrays to PyTorch tensors.
        
        Args:
            device: Optional device to place tensors on
            
        Returns:
            Dictionary of PyTorch tensors
        """
        tensors = {
            'labels': torch.tensor(self.labels, dtype=torch.long),
            'attention_mask': torch.tensor(self.attention_mask, dtype=torch.long)
        }
        
        # Convert task-specific labels
        if hasattr(self, 'task_labels'):
            for task_name, task_labels in self.task_labels.items():
                # Determine appropriate dtype for the labels
                if task_name in ('MLM', 'LMLM', 'NSP', 'DISCOURSE'):
                    dtype = torch.long
                elif task_name in ('SENTIMENT', 'NER', 'POS'):
                    dtype = torch.long
                elif task_name == 'CONTRASTIVE':
                    # Contrastive labels might be floats (e.g., similarity scores)
                    dtype = torch.float
                else:
                    dtype = torch.long
                    
                tensors[f'{task_name.lower()}_labels'] = torch.tensor(task_labels.labels, dtype=dtype)
                
                if task_labels.mask is not None:
                    tensors[f'{task_name.lower()}_mask'] = torch.tensor(task_labels.mask, dtype=torch.long)
        
        # Move tensors to specified device if provided
        if device is not None:
            tensors = {k: v.to(device) for k, v in tensors.items()}
            
        return tensors


@dataclass
class StaticInput(BaseInput):
    """Input container optimized for static embedding models like Word2Vec.
    
    Attributes:
        center_words: Center word token IDs for algorithms like CBOW/Skip-gram
        context_words: Context word token IDs surrounding center words
        context_mask: Mask indicating which context positions are valid
        negative_samples: Optional negative sample token IDs for negative sampling
        metadata: Optional additional metadata
    """
    center_words: np.ndarray
    context_words: np.ndarray
    context_mask: np.ndarray
    negative_samples: Optional[np.ndarray] = None
    metadata: Optional[Dict[str, Any]] = None  # Add back explicitly at the end
    
    def to_tensors(self, device=None) -> Dict[str, torch.Tensor]:
        """Convert numpy arrays to PyTorch tensors.
        
        Args:
            device: Optional device to place tensors on
            
        Returns:
            Dictionary of PyTorch tensors
        """
        tensors = {
            'center_words': torch.tensor(self.center_words, dtype=torch.long),
            'context_words': torch.tensor(self.context_words, dtype=torch.long),
            'context_mask': torch.tensor(self.context_mask, dtype=torch.long)
        }
        
        if self.negative_samples is not None:
            tensors['negative_samples'] = torch.tensor(self.negative_samples, dtype=torch.long)
        
        # Move tensors to specified device if provided
        if device is not None:
            tensors = {k: v.to(device) for k, v in tensors.items()}
            
        return tensors


@dataclass
class StaticTarget(BaseTarget):
    """Target container optimized for static embedding models like Word2Vec.
    
    Attributes:
        target_values: Target values (often binary for skip-gram or word IDs for CBOW)
        target_mask: Mask indicating which targets are valid
        task_labels: Dictionary of task-specific labels that can be applied to static models
        metadata: Optional additional metadata
    """
    target_values: np.ndarray
    target_mask: np.ndarray
    task_labels: Dict[str, TaskLabels] = field(default_factory=dict)  # Add back explicitly at the end
    metadata: Optional[Dict[str, Any]] = None  # Add back explicitly at the end
    
    def to_tensors(self, device=None) -> Dict[str, torch.Tensor]:
        """Convert numpy arrays to PyTorch tensors.
        
        Args:
            device: Optional device to place tensors on
            
        Returns:
            Dictionary of PyTorch tensors
        """
        tensors = {
            'target_values': torch.tensor(self.target_values, dtype=torch.long),
            'target_mask': torch.tensor(self.target_mask, dtype=torch.long)
        }
        
        # Convert task-specific labels
        if hasattr(self, 'task_labels'):
            for task_name, task_labels in self.task_labels.items():
                # Determine appropriate dtype for the labels
                if task_name in ('MLM', 'LMLM', 'NSP', 'DISCOURSE'):
                    dtype = torch.long
                elif task_name in ('SENTIMENT', 'NER', 'POS'):
                    dtype = torch.long
                elif task_name == 'CONTRASTIVE':
                    # Contrastive labels might be floats (e.g., similarity scores)
                    dtype = torch.float
                else:
                    dtype = torch.long
                    
                tensors[f'{task_name.lower()}_labels'] = torch.tensor(task_labels.labels, dtype=dtype)
                
                if task_labels.mask is not None:
                    tensors[f'{task_name.lower()}_mask'] = torch.tensor(task_labels.mask, dtype=torch.long)
        
        # Move tensors to specified device if provided
        if device is not None:
            tensors = {k: v.to(device) for k, v in tensors.items()}
            
        return tensors


def create_transformer_batch(
    inputs: List[TransformerInput],
    targets: List[TransformerTarget],
    device=None
) -> Tuple[Dict[str, torch.Tensor], Dict[str, torch.Tensor]]:
    """Create batched tensors from lists of transformer inputs and targets.
    
    Args:
        inputs: List of TransformerInput objects
        targets: List of TransformerTarget objects
        device: Optional device to place tensors on
        
    Returns:
        Tuple of (batched input tensors, batched target tensors)
    """
    # Batch size validation
    if len(inputs) != len(targets):
        raise ValueError(f"Mismatched batch sizes: {len(inputs)} inputs vs {len(targets)} targets")
    
    # Combine individual examples into batch
    batch_inputs = {}
    batch_targets = {}
    
    # Process all inputs
    for field_name in ['input_ids', 'attention_mask', 'token_type_ids', 
                     'position_ids', 'special_tokens_mask', 'mlm_mask']:
        # Collect values from all examples
        values = [getattr(inp, field_name) for inp in inputs if hasattr(inp, field_name) and getattr(inp, field_name) is not None]
        
        # Skip if no values available for this field
        if not values:
            continue
        
        # Stack into batch
        batch_inputs[field_name] = torch.stack([torch.tensor(v, dtype=torch.long) for v in values])
    
    # Process all targets
    # Core fields
    batch_targets['labels'] = torch.stack([torch.tensor(t.labels, dtype=torch.long) for t in targets])
    batch_targets['attention_mask'] = torch.stack([torch.tensor(t.attention_mask, dtype=torch.long) for t in targets])
    
    # Process task labels
    # First find all unique task names across the batch
    all_task_names = set()
    for target in targets:
        if hasattr(target, 'task_labels'):
            all_task_names.update(target.task_labels.keys())
    
    # Now process each task
    for task_name in all_task_names:
        # Labels
        task_labels = []
        task_masks = []
        
        for target in targets:
            if hasattr(target, 'task_labels') and task_name in target.task_labels:
                task_labels.append(target.task_labels[task_name].labels)
                
                if target.task_labels[task_name].mask is not None:
                    task_masks.append(target.task_labels[task_name].mask)
        
        # Determine appropriate dtype
        if task_name in ('MLM', 'LMLM', 'NSP', 'DISCOURSE', 'SENTIMENT', 'NER', 'POS'):
            dtype = torch.long
        else:
            dtype = torch.float
            
        # Only add to batch if we have examples
        if task_labels:
            batch_targets[f'{task_name.lower()}_labels'] = torch.stack([torch.tensor(lbl, dtype=dtype) for lbl in task_labels])
            
        if task_masks:
            batch_targets[f'{task_name.lower()}_mask'] = torch.stack([torch.tensor(mask, dtype=torch.long) for mask in task_masks])
    
    # Move to device if specified
    if device is not None:
        batch_inputs = {k: v.to(device) for k, v in batch_inputs.items()}
        batch_targets = {k: v.to(device) for k, v in batch_targets.items()}
    
    return batch_inputs, batch_targets


def create_static_batch(
    inputs: List[StaticInput],
    targets: List[StaticTarget],
    device=None
) -> Tuple[Dict[str, torch.Tensor], Dict[str, torch.Tensor]]:
    """Create batched tensors from lists of static inputs and targets.
    
    Args:
        inputs: List of StaticInput objects
        targets: List of StaticTarget objects
        device: Optional device to place tensors on
        
    Returns:
        Tuple of (batched input tensors, batched target tensors)
    """
    # Batch size validation
    if len(inputs) != len(targets):
        raise ValueError(f"Mismatched batch sizes: {len(inputs)} inputs vs {len(targets)} targets")
    
    # Combine individual examples into batch
    batch_inputs = {}
    batch_targets = {}
    
    # Process all inputs
    batch_inputs['center_words'] = torch.stack([torch.tensor(inp.center_words, dtype=torch.long) for inp in inputs])
    batch_inputs['context_words'] = torch.stack([torch.tensor(inp.context_words, dtype=torch.long) for inp in inputs])
    batch_inputs['context_mask'] = torch.stack([torch.tensor(inp.context_mask, dtype=torch.long) for inp in inputs])
    
    # Add negative samples if available
    if all(inp.negative_samples is not None for inp in inputs):
        batch_inputs['negative_samples'] = torch.stack([torch.tensor(inp.negative_samples, dtype=torch.long) for inp in inputs])
    
    # Process all targets
    batch_targets['target_values'] = torch.stack([torch.tensor(t.target_values, dtype=torch.long) for t in targets])
    batch_targets['target_mask'] = torch.stack([torch.tensor(t.target_mask, dtype=torch.long) for t in targets])
    
    # Process task labels
    # First find all unique task names across the batch
    all_task_names = set()
    for target in targets:
        if hasattr(target, 'task_labels'):
            all_task_names.update(target.task_labels.keys())
    
    # Now process each task
    for task_name in all_task_names:
        # Labels
        task_labels = []
        task_masks = []
        
        for target in targets:
            if hasattr(target, 'task_labels') and task_name in target.task_labels:
                task_labels.append(target.task_labels[task_name].labels)
                
                if target.task_labels[task_name].mask is not None:
                    task_masks.append(target.task_labels[task_name].mask)
        
        # Determine appropriate dtype
        if task_name in ('MLM', 'LMLM', 'NSP', 'DISCOURSE', 'SENTIMENT', 'NER', 'POS'):
            dtype = torch.long
        else:
            dtype = torch.float
            
        # Only add to batch if we have examples
        if task_labels:
            batch_targets[f'{task_name.lower()}_labels'] = torch.stack([torch.tensor(lbl, dtype=dtype) for lbl in task_labels])
            
        if task_masks:
            batch_targets[f'{task_name.lower()}_mask'] = torch.stack([torch.tensor(mask, dtype=torch.long) for mask in task_masks])
    
    # Move to device if specified
    if device is not None:
        batch_inputs = {k: v.to(device) for k, v in batch_inputs.items()}
        batch_targets = {k: v.to(device) for k, v in batch_targets.items()}
    
    return batch_inputs, batch_targets