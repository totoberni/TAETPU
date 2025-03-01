"""
Webapp integration utilities for the monitoring system.
Provides functions to export metrics in webapp-friendly formats and API interfaces.
"""
import os
import json
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, List, Optional

from ..logging.cls_logging import log, log_success, log_warning, log_error, ensure_directory
from ..logging.config_loader import get_config

def configure_webapp_export(monitor_name: str, config: Dict[str, Any]) -> bool:
    """
    Configure a monitor for webapp export based on configuration
    
    Args:
        monitor_name: Name of the monitor
        config: Configuration dictionary for the monitor
        
    Returns:
        bool: True if webapp export is enabled, False otherwise
    """
    # Get webapp configuration
    webapp_config = config.get("webapp", {})
    
    # Check if webapp integration is enabled
    if not webapp_config.get("enable_realtime_api", False):
        return False
    
    # Create export directory if needed
    log_dir = config.get(monitor_name, {}).get("log_dir", f"logs/{monitor_name}")
    ensure_directory(log_dir)
    
    log_success(f"Webapp export enabled for {monitor_name}")
    return True

def export_metrics_to_json(
    monitor_name: str, 
    metrics: Dict[str, Any], 
    status: str = "ok", 
    metadata: Optional[Dict[str, Any]] = None,
    log_dir: Optional[str] = None
) -> str:
    """
    Export metrics to a JSON file for webapp consumption
    
    Args:
        monitor_name: Name of the monitor
        metrics: Dictionary of metrics to export
        status: Status string (ok, warning, error)
        metadata: Optional metadata to include
        log_dir: Directory to save the JSON file (if None, use default)
        
    Returns:
        str: Path to the exported JSON file
    """
    # Create metrics data structure
    export_data = {
        "timestamp": datetime.now().isoformat(),
        "monitor": monitor_name,
        "status": status,
        "metrics": metrics,
        "metadata": metadata or {}
    }
    
    # Determine log directory
    if not log_dir:
        # Get from configuration
        config = get_config()
        log_dir = config.get(monitor_name, {}).get("log_dir", f"logs/{monitor_name}")
        
    # Ensure directory exists
    ensure_directory(log_dir)
    
    # Create file path
    latest_path = os.path.join(log_dir, "latest_metrics.json")
    
    # Write metrics to file
    try:
        with open(latest_path, "w") as f:
            json.dump(export_data, f, indent=2)
        return latest_path
    except Exception as e:
        log_error(f"Failed to export metrics to {latest_path}: {e}")
        return ""

def create_webapp_metrics(
    metrics: Dict[str, Any], 
    metadata: Optional[Dict[str, Any]] = None
) -> Dict[str, Any]:
    """
    Create a webapp-friendly metrics structure
    
    Args:
        metrics: Raw metrics dictionary
        metadata: Optional metadata to include
        
    Returns:
        dict: Webapp-friendly metrics structure with flattened values
    """
    # Create base structure
    webapp_metrics = {
        "timestamp": datetime.now().isoformat(),
        "status": "ok"
    }
    
    # Add flattened metrics
    for key, value in metrics.items():
        if isinstance(value, (int, float, str, bool)):
            # Simple values added directly
            webapp_metrics[key] = value
        elif isinstance(value, dict):
            # Handle nested dictionaries by flattening with dot notation
            for subkey, subvalue in value.items():
                if isinstance(subvalue, (int, float, str, bool)):
                    webapp_metrics[f"{key}.{subkey}"] = subvalue
    
    # Add metadata with prefix
    if metadata:
        for key, value in metadata.items():
            if isinstance(value, (int, float, str, bool)):
                webapp_metrics[f"metadata.{key}"] = value
    
    return webapp_metrics

def archive_metrics(monitor_name: str, retention_days: int = 7) -> int:
    """
    Archive metrics older than retention_days and clean up old archives
    
    Args:
        monitor_name: Name of the monitor
        retention_days: Number of days to keep metrics
        
    Returns:
        int: Number of files deleted
    """
    # Get configuration
    config = get_config()
    log_dir = config.get(monitor_name, {}).get("log_dir", f"logs/{monitor_name}")
    
    # Calculate cutoff time
    now = time.time()
    cutoff_time = now - (retention_days * 24 * 60 * 60)
    
    # Find and delete old sample files
    deleted_count = 0
    try:
        for file in Path(log_dir).glob("samples_*.json"):
            # Check file modification time
            mtime = file.stat().st_mtime
            if mtime < cutoff_time:
                file.unlink()
                deleted_count += 1
        
        if deleted_count > 0:
            log(f"Archived {deleted_count} old metric files for {monitor_name}")
        
        return deleted_count
    except Exception as e:
        log_error(f"Error archiving metrics for {monitor_name}: {e}")
        return 0 