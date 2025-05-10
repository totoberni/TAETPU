"""Cache management for Transformer Ablation Experiment."""

import os
import logging
import pickle
import time
from pathlib import Path
from typing import Any, Optional, Dict, Union, List

# Configure logging
logger = logging.getLogger(__name__)

# Import shared utilities
from ..utils import DATA_PATHS, safe_operation, ensure_directories_exist

# Create cache directories
os.makedirs(DATA_PATHS['CACHE_PREP_DIR'], exist_ok=True)

def get_cache_path(cache_key: str, cache_subdir: Optional[str] = None) -> str:
    """
    Get the path to a cache file with the given key.
    
    Args:
        cache_key: Unique identifier for the cache entry
        cache_subdir: Optional subdirectory within the cache directory
        
    Returns:
        Full path to the cache file
    """
    base_dir = DATA_PATHS['CACHE_PREP_DIR']
    
    if cache_subdir:
        cache_dir = os.path.join(base_dir, cache_subdir)
        ensure_directories_exist([cache_dir])
    else:
        cache_dir = base_dir
        
    # Make the key filename-safe
    safe_key = "".join(c if c.isalnum() else "_" for c in cache_key)
    
    return os.path.join(cache_dir, f"{safe_key}.pkl")

def is_cache_valid(cache_path: str, max_age_hours: int = 72) -> bool:
    """
    Check if cache file exists and is not too old.
    
    Args:
        cache_path: Path to cache file
        max_age_hours: Maximum age in hours for valid cache
        
    Returns:
        True if cache is valid, False otherwise
    """
    if not os.path.exists(cache_path):
        return False
    
    # Check file age
    file_time = os.path.getmtime(cache_path)
    age_hours = (time.time() - file_time) / 3600
    
    return age_hours < max_age_hours

@safe_operation("cache saving", default_return="")
def save_to_cache(obj: Any, cache_key: str, cache_subdir: Optional[str] = None) -> str:
    """
    Save an object to the cache.
    
    Args:
        obj: Object to cache
        cache_key: Unique identifier for the cache entry
        cache_subdir: Optional subdirectory within the cache directory
        
    Returns:
        Path to the saved cache file or empty string if saving failed
    """
    cache_path = get_cache_path(cache_key, cache_subdir)
    
    with open(cache_path, 'wb') as f:
        pickle.dump(obj, f)
    logger.debug(f"Saved to cache: {cache_path}")
    return cache_path

@safe_operation("cache loading", default_return=None)
def load_from_cache(cache_key: str, cache_subdir: Optional[str] = None) -> Optional[Any]:
    """
    Load an object from the cache.
    
    Args:
        cache_key: Unique identifier for the cache entry
        cache_subdir: Optional subdirectory within the cache directory
        
    Returns:
        Cached object if found, None otherwise
    """
    cache_path = get_cache_path(cache_key, cache_subdir)
    
    if not os.path.exists(cache_path):
        logger.debug(f"Cache miss: {cache_path}")
        return None
    
    with open(cache_path, 'rb') as f:
        obj = pickle.load(f)
    logger.debug(f"Loaded from cache: {cache_path}")
    return obj

def cache_exists(cache_key: str, cache_subdir: Optional[str] = None) -> bool:
    """
    Check if a cache entry exists.
    
    Args:
        cache_key: Unique identifier for the cache entry
        cache_subdir: Optional subdirectory within the cache directory
        
    Returns:
        True if cache exists, False otherwise
    """
    cache_path = get_cache_path(cache_key, cache_subdir)
    return os.path.exists(cache_path)

@safe_operation("cache clearing", default_return=0)
def clear_cache(cache_subdir: Optional[str] = None) -> int:
    """
    Clear cache files.
    
    Args:
        cache_subdir: Optional subdirectory to clear (clears all if None)
        
    Returns:
        Number of files cleared
    """
    if cache_subdir:
        cache_dir = os.path.join(DATA_PATHS['CACHE_PREP_DIR'], cache_subdir)
    else:
        cache_dir = DATA_PATHS['CACHE_PREP_DIR']
        
    if not os.path.exists(cache_dir):
        return 0
        
    count = 0
    for file in os.listdir(cache_dir):
        if file.endswith('.pkl'):
            os.remove(os.path.join(cache_dir, file))
            count += 1
                
    logger.info(f"Cleared {count} cache files from {cache_dir}")
    return count

__all__ = [
    'get_cache_path',
    'is_cache_valid',
    'save_to_cache',
    'load_from_cache',
    'cache_exists',
    'clear_cache'
] 