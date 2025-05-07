"""
Contrastive learning task generators.

This module implements generators for contrastive learning tasks
with cluster validation for similarity-based learning.
"""

import logging
import numpy as np
import random
from typing import Dict, List, Optional, Any
from tqdm import tqdm

from .base import TaskGenerator

# Configure logger
logger = logging.getLogger('tasks.contrastive')

class ContrastiveGenerator(TaskGenerator):
    """Generator for Contrastive Learning task with cluster validation."""
    
    def __init__(self, config: Dict):
        super().__init__(config)
        self.clustering_method = self.config.get('clustering_method', 'kmeans')
        self.min_clusters = self.config.get('min_clusters', 3)
        self.max_clusters = self.config.get('max_clusters', 8)
    
    def supports_model_type(self, model_type: str) -> bool:
        """Contrastive learning supports both transformer and static models."""
        return model_type in ['transformer', 'static']
    
    def generate_labels(self, inputs: List[Any], tokenizer: Any = None) -> List[Any]:
        """Generate contrastive learning labels with clustering."""
        logger.info(f"Generating contrastive learning labels")
        
        # For contrastive learning, we need to process all examples together
        # to create clusters and determine similarity scores
        
        try:
            from sklearn.cluster import KMeans
            from sklearn.metrics import silhouette_score
        except ImportError:
            logger.error("scikit-learn is not installed. Install with 'pip install scikit-learn'")
            return [None] * len(inputs)
        
        # Extract features for clustering
        # Since we don't have actual embeddings yet, we'll use token statistics as proxy features
        features = []
        for inp in inputs:
            if hasattr(inp, 'input_ids') and hasattr(inp, 'attention_mask'):
                # For transformer inputs
                # Simple features: sequence length, ratio of special tokens, etc.
                seq_len = inp.attention_mask.sum()
                if hasattr(inp, 'special_tokens_mask'):
                    special_ratio = inp.special_tokens_mask.sum() / max(seq_len, 1)
                else:
                    special_ratio = 0.0
                
                # Extract more features from metadata if available
                if hasattr(inp, 'metadata'):
                    # Text length in words
                    word_count = inp.metadata.get('original_length', 0)
                    # Average word length
                    if word_count > 0:
                        avg_word_len = len(inp.metadata.get('original_text', '')) / word_count
                    else:
                        avg_word_len = 0
                else:
                    word_count = 0
                    avg_word_len = 0
                
                features.append([seq_len, special_ratio, word_count, avg_word_len])
            
            elif hasattr(inp, 'center_words') and hasattr(inp, 'context_words'):
                # For static inputs
                center_count = len(inp.center_words)
                context_count = inp.context_mask.sum()
                
                if hasattr(inp, 'metadata'):
                    word_count = inp.metadata.get('original_length', 0)
                    avg_word_len = len(inp.metadata.get('original_text', '')) / max(word_count, 1)
                else:
                    word_count = 0
                    avg_word_len = 0
                
                features.append([center_count, context_count, word_count, avg_word_len])
            
            else:
                # Skip if input format is not recognized
                features.append([0, 0, 0, 0])
        
        # Convert to array
        features = np.array(features, dtype=np.float32)
        
        # Skip clustering if too few examples
        if len(features) < self.min_clusters * 2:
            logger.warning(f"Not enough examples for clustering ({len(features)} < {self.min_clusters * 2})")
            from ..types import TaskLabels
            return [TaskLabels(
                labels=np.array([0], dtype=np.int64),
                mask=np.array([1], dtype=np.int32)
            ) for _ in inputs]
        
        # Find optimal number of clusters
        best_score = -1
        best_clusters = None
        best_k = self.min_clusters
        
        # Try different cluster counts
        for k in range(self.min_clusters, min(self.max_clusters + 1, len(features) // 2)):
            kmeans = KMeans(n_clusters=k, random_state=42, n_init=10)
            clusters = kmeans.fit_predict(features)
            
            # Calculate silhouette score
            score = silhouette_score(features, clusters)
            
            if score > best_score:
                best_score = score
                best_clusters = clusters
                best_k = k
        
        # Create task labels
        from ..types import TaskLabels
        task_labels = []
        for i, cluster in enumerate(best_clusters):
            # Create single-element task labels array with cluster ID
            labels = np.array([cluster], dtype=np.int64)
            
            # Create TaskLabels object
            task_labels.append(TaskLabels(
                labels=labels,
                mask=np.array([1]),  # Always attend to cluster label
                metadata={
                    'silhouette_score': best_score,
                    'num_clusters': best_k,
                    'features': features[i]
                }
            ))
        
        logger.info(f"Created {best_k} clusters with silhouette score {best_score:.4f}")
        return task_labels 