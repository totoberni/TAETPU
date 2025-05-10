"""Centralized caching functionality for the TAETPU project.

This module provides a unified caching system for:
- Saving and loading data to/from disk cache
- Validating cache freshness using configuration hashes
- Managing cache files and directories
- Efficient reuse of computationally expensive operations
"""

import os
import pickle
import hashlib
import logging
from typing import Any, Dict, Optional, Tuple, Union

# Configure logging
logger = logging.getLogger(__name__)

def save_to_cache(data: Any, cache_file: str) -> bool:
    """Save data to cache file.
    
    Args:
        data: Data to be cached
        cache_file: Path to cache file
        
    Returns:
        True if successful, False otherwise
    """
    try:
        os.makedirs(os.path.dirname(cache_file), exist_ok=True)
        with open(cache_file, 'wb') as f:
            pickle.dump(data, f)
        logger.debug(f"Data saved to cache: {cache_file}")
        return True
    except Exception as e:
        logger.error(f"Failed to save data to cache {cache_file}: {e}")
        return False

def load_from_cache(cache_file: str) -> Optional[Any]:
    """Load data from cache file.
    
    Args:
        cache_file: Path to cache file
        
    Returns:
        Cached data if available, None otherwise
    """
    if not os.path.exists(cache_file):
        logger.debug(f"Cache file not found: {cache_file}")
        return None
    
    try:
        with open(cache_file, 'rb') as f:
            data = pickle.load(f)
        logger.debug(f"Data loaded from cache: {cache_file}")
        return data
    except Exception as e:
        logger.error(f"Failed to load data from cache {cache_file}: {e}")
        return None

def is_cache_valid(cache_file: str, config_hash: str) -> bool:
    """Check if cache file is valid based on config hash.
    
    Args:
        cache_file: Path to cache file
        config_hash: Hash of configuration to validate against
        
    Returns:
        True if cache is valid, False otherwise
    """
    if not os.path.exists(cache_file):
        return False
    
    try:
        with open(f"{cache_file}.hash", "r") as f:
            stored_hash = f.read().strip()
        return stored_hash == config_hash
    except Exception as e:
        logger.error(f"Failed to validate cache {cache_file}: {e}")
        return False

def cache_exists(cache_file: str) -> bool:
    """Check if cache file exists.
    
    Args:
        cache_file: Path to cache file
        
    Returns:
        True if cache exists, False otherwise
    """
    return os.path.exists(cache_file)

def clear_cache(cache_file: Optional[str] = None) -> bool:
    """Clear cache files.
    
    Args:
        cache_file: Specific cache file to clear, or None to clear all
        
    Returns:
        True if successful, False otherwise
    """
    try:
        if cache_file:
            if os.path.exists(cache_file):
                os.remove(cache_file)
            if os.path.exists(f"{cache_file}.hash"):
                os.remove(f"{cache_file}.hash")
            logger.debug(f"Cleared cache: {cache_file}")
        else:
            # Implementation for clearing all cache would go here
            pass
        return True
    except Exception as e:
        logger.error(f"Failed to clear cache: {e}")
        return False

# Make all cache functions available at the module level
__all__ = [
    'save_to_cache',
    'load_from_cache',
    'is_cache_valid',
    'cache_exists',
    'clear_cache'
] 