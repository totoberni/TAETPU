"""
Core data structures for transformer and static embedding models.

This module defines the data structures used for inputs, targets, and task labels
for both transformer models and static embedding models.
"""

import numpy as np
from typing import Dict, List, Optional, Any, Union, NamedTuple
from dataclasses import dataclass, field

@dataclass
class TaskLabels:
    """Task-specific labels for model training."""
    
    labels: np.ndarray
    """Labels for the task."""
    
    mask: Optional[np.ndarray] = None
    """Mask indicating valid positions for the task."""
    
    metadata: Dict[str, Any] = field(default_factory=dict)
    """Additional metadata for the task."""

@dataclass
class TransformerInput:
    """Input data for transformer models."""
    
    input_ids: np.ndarray
    """Token IDs for the input sequence."""
    
    attention_mask: np.ndarray
    """Attention mask for the input sequence."""
    
    token_type_ids: Optional[np.ndarray] = None
    """Token type IDs for the input sequence."""
    
    special_tokens_mask: Optional[np.ndarray] = None
    """Mask indicating special tokens."""
    
    metadata: Dict[str, Any] = field(default_factory=dict)
    """Additional metadata about the input."""

@dataclass
class TransformerTarget:
    """Target data for transformer models."""
    
    labels: np.ndarray
    """Label IDs for the target sequence."""
    
    attention_mask: np.ndarray
    """Attention mask for the target sequence."""
    
    task_labels: Dict[str, TaskLabels] = field(default_factory=dict)
    """Task-specific labels for different training objectives."""
    
    metadata: Dict[str, Any] = field(default_factory=dict)
    """Additional metadata about the target."""

@dataclass
class StaticInput:
    """Input data for static embedding models."""
    
    center_words: np.ndarray
    """Center words for the context window."""
    
    context_words: np.ndarray
    """Context words surrounding the center words."""
    
    context_mask: np.ndarray
    """Mask indicating valid context words."""
    
    metadata: Dict[str, Any] = field(default_factory=dict)
    """Additional metadata about the input."""

@dataclass
class StaticTarget:
    """Target data for static embedding models."""
    
    target_values: np.ndarray
    """Target values for training."""
    
    target_mask: np.ndarray
    """Mask indicating valid target positions."""
    
    task_labels: Dict[str, TaskLabels] = field(default_factory=dict)
    """Task-specific labels for different training objectives."""
    
    metadata: Dict[str, Any] = field(default_factory=dict)
    """Additional metadata about the target.""" 