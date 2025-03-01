#!/usr/bin/env python3
"""
Path utilities for handling both local and GCS file paths.
"""
import os
from pathlib import Path

def resolve_path(path, base_dir=None, use_gcs=False, bucket_name=None, gcs_base_dir=None):
    """
    Resolve a path based on whether it should be local or in GCS.
    
    Args:
        path: The relative path to resolve
        base_dir: Base directory for local paths (default: current directory)
        use_gcs: Whether to use GCS paths
        bucket_name: Name of the GCS bucket (required if use_gcs=True)
        gcs_base_dir: Base directory in GCS bucket (default: "")
        
    Returns:
        str: The resolved path (either local or GCS)
    """
    if use_gcs and bucket_name:
        # Create the full path to GCS
        gcs_base = gcs_base_dir or ""
        if gcs_base and not gcs_base.endswith('/'):
            gcs_base += '/'
        
        # Remove leading slashes from path for GCS
        clean_path = path.lstrip('/')
        
        return f"gs://{bucket_name}/{gcs_base}{clean_path}"
    else:
        # Use local path
        if base_dir:
            return os.path.join(base_dir, path)
        else:
            return path

def ensure_directory(path, is_gcs=False):
    """
    Ensure a directory exists (for local paths only).
    For GCS paths, this is a no-op as directories are created implicitly.
    
    Args:
        path: Path to ensure exists
        is_gcs: Whether this is a GCS path
    """
    if not is_gcs and path and not path.startswith('gs://'):
        os.makedirs(path, exist_ok=True)
        return True
    return False

def is_gcs_path(path):
    """
    Check if a path is a GCS path.
    
    Args:
        path: Path to check
        
    Returns:
        bool: True if it's a GCS path, False otherwise
    """
    return path.startswith('gs://')

def path_exists(path):
    """
    Check if a path exists. Works for both local and GCS paths.
    Note: For GCS paths, this will always return True as we can't easily check 
    without importing additional dependencies.
    
    Args:
        path: Path to check
        
    Returns:
        bool: True if the path exists, False otherwise
    """
    if is_gcs_path(path):
        # For GCS paths, we assume they exist or will be created
        return True
    else:
        return os.path.exists(path) 