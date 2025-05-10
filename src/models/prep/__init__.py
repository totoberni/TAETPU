"""Preprocessing models for transformer datasets."""

import os
import sys
import logging

# Configure logging
logger = logging.getLogger(__name__)

# Import shared utilities
try:
    from src import optimize_tensor_dimensions, is_tpu_available
except ImportError:
    # Fallback for direct execution
    sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../../..')))
    from src import optimize_tensor_dimensions, is_tpu_available

# Will contain preprocessing model implementations
__all__ = [] 