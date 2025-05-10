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