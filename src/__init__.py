"""Transformer Ablation Experiment TPU (TAETPU) Framework.

A comprehensive framework for conducting Transformer model architecture 
ablation experiments on Google Cloud TPUs. It provides:

- Infrastructure for TPU configuration and optimization
- Data preprocessing for TPU compatibility
- Model components with modularity for experiments
- Caching system for efficiency in experimentation
- Utilities for managing configurations and experiment tracking

This framework is designed to facilitate research into the importance 
of different Transformer architecture components.
"""

import os
import sys
import logging
from pathlib import Path

# Configure root logger
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)

# Import core subpackages
from . import utils
from . import configs
from . import tpu
from . import cache
from . import models
from . import data

# Optional: Register model types (if needed for experiments)
def register_model_types():
    """Register custom model types for experiments."""
    pass

# Export all subpackages
__all__ = [
    'utils',
    'configs',
    'tpu',
    'cache',
    'models',
    'data'
]