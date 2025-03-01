#!/usr/bin/env python3
"""
Script for starting TensorBoard dashboards for monitoring visualization.
"""
import os
import sys
import argparse
import subprocess
from pathlib import Path

# Add the parent directory to the path to allow importing
parent_dir = Path(__file__).resolve().parent.parent.parent
if str(parent_dir) not in sys.path:
    sys.path.insert(0, str(parent_dir))

# Use relative imports for local modules
from ..logging.cls_logging import log, log_success, log_warning, log_error
from ..logging.config_loader import get_config
from ..logging.path_utils import path_exists, ensure_directory
from .super_dashboard import Dashboard
from .tpu_dashboard import TPUDashboard
from .bucket_dashboard import BucketDashboard

def start_tensorboard(logdir, host="0.0.0.0", port=6006, background=True):
    """
    Start TensorBoard to visualize logs
    
    Args:
        logdir: Directory containing TensorBoard logs
        host: Host to bind the server to
        port: Port to bind the server to
        background: Whether to start in background (True) or wait for server (False)
    
    Returns:
        subprocess.Popen: The process object if background=True, None otherwise
    """
    if not path_exists(logdir):
        log_warning(f"TensorBoard log directory not found: {logdir}")
        # Create the directory if it doesn't exist
        ensure_directory(logdir)
        log("Created TensorBoard log directory")
    
    # Build the command
    cmd = [
        "tensorboard",
        "--logdir", logdir,
        "--host", host,
        "--port", str(port)
    ]
    
    try:
        if background:
            # Start in background
            process = subprocess.Popen(
                cmd, 
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            log_success(f"Started TensorBoard in background (PID: {process.pid})")
            log_success(f"TensorBoard will be accessible at http://{host}:{port}")
            return process
        else:
            # Start and wait for completion (blocking)
            log("Starting TensorBoard (press Ctrl+C to stop)...")
            result = subprocess.run(
                cmd,
                capture_output=False,
                text=True
            )
            if result.returncode == 0:
                log_success("TensorBoard finished successfully")
            else:
                log_error(f"TensorBoard exited with error code: {result.returncode}")
            return None
    except Exception as e:
        log_error(f"Error starting TensorBoard: {e}")
        return None

def start_dashboards(config_path=None, host="0.0.0.0", port=6006, background=True):
    """
    Start dashboards based on configuration
    
    Args:
        config_path: Path to configuration file
        host: Host to bind the server to
        port: Port to bind the server to
        background: Whether to start in background (True) or foreground (False)
        
    Returns:
        tuple: (dict of dashboards, TensorBoard process or None)
    """
    # Load configuration
    config = get_config(config_path)
    
    # Check if config was loaded
    if not config:
        log_error("Failed to load configuration. Using defaults.")
    
    # Create dashboards
    dashboards = {}
    
    # Create TPU dashboard if enabled
    tpu_dashboard_config = config.get("dashboards", {}).get("tpu_dashboard", {})
    if tpu_dashboard_config.get("enabled", True):
        try:
            log("Creating TPU dashboard...")
            tpu_dashboard = TPUDashboard(config=config)
            dashboards["tpu"] = tpu_dashboard
            log_success("TPU dashboard created")
        except Exception as e:
            log_error(f"Failed to create TPU dashboard: {e}")
    
    # Create Bucket dashboard if enabled
    bucket_dashboard_config = config.get("dashboards", {}).get("bucket_dashboard", {})
    if bucket_dashboard_config.get("enabled", True):
        try:
            log("Creating Bucket dashboard...")
            bucket_dashboard = BucketDashboard(config=config)
            dashboards["bucket"] = bucket_dashboard
            log_success("Bucket dashboard created")
        except Exception as e:
            log_error(f"Failed to create Bucket dashboard: {e}")
    
    # Use the first dashboard's log directory or fall back to default
    if dashboards:
        first_dashboard = list(dashboards.values())[0]
        logdir = first_dashboard.tb_log_dir
    else:
        log_warning("No dashboards created. Using default log directory.")
        logdir = os.path.join("logs", "tensorboard")
    
    # Start TensorBoard
    tensorboard_process = start_tensorboard(logdir, host, port, background)
    
    return dashboards, tensorboard_process

def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(description="Start dashboard for monitoring visualization")
    parser.add_argument("--config", "-c", help="Path to configuration file")
    parser.add_argument("--logdir", "-d", help="Directory containing TensorBoard logs (overrides config)")
    parser.add_argument("--host", default="0.0.0.0", help="Host to bind the server to")
    parser.add_argument("--port", "-p", type=int, default=6006, help="Port to bind the server to")
    parser.add_argument("--background", "-b", action="store_true", help="Run in background")
    parser.add_argument("--foreground", "-f", action="store_true", help="Run in foreground (default)")
    
    args = parser.parse_args()
    
    # Check config file exists if specified
    if args.config and not path_exists(args.config):
        log_error(f"Config file not found: {args.config}")
        return 1
    
    # Determine background mode (default is foreground)
    background = args.background and not args.foreground
    
    # Start either directly or via dashboard configuration
    if args.logdir:
        # Direct TensorBoard start with specified log directory
        process = start_tensorboard(args.logdir, args.host, args.port, background)
        if not background and process is None:
            return 1
    else:
        # Start with dashboard configuration
        dashboards, process = start_dashboards(args.config, args.host, args.port, background)
        
        if not process:
            log_error("Failed to start TensorBoard server")
            return 1
    
    # For foreground mode, we're already waiting in the start_tensorboard call
    # For background mode, we just return success
    return 0

if __name__ == "__main__":
    sys.exit(main()) 