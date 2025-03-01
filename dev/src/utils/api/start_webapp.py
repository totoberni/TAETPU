#!/usr/bin/env python3
"""
Unified launcher for TPU monitoring system web components.
This provides:
1. REST API to access monitoring data
2. TensorBoard visualization of monitoring metrics
"""
import os
import sys
import argparse
import subprocess
import time
from pathlib import Path

# Add the parent directory to the path to allow importing
parent_dir = Path(__file__).resolve().parent.parent.parent
if str(parent_dir) not in sys.path:
    sys.path.insert(0, str(parent_dir))

from dev.src.utils.logging.cls_logging import log, log_success, log_warning, log_error
from dev.src.utils.logging.config_loader import get_config

# Try to import webapp API modules
try:
    from utils.api.webapp_api import configure, start_server
    API_AVAILABLE = True
except ImportError:
    API_AVAILABLE = False
    log_warning("API modules not available; webapp API server will be disabled")

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
    # Build the command
    cmd = [
        sys.executable, "-m", "tensorboard.main", 
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
            # Start and wait for completion
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True
            )
            if result.returncode == 0:
                log_success("TensorBoard started successfully")
            else:
                log_error(f"Failed to start TensorBoard: {result.stderr}")
            return None
    except Exception as e:
        log_error(f"Error starting TensorBoard: {e}")
        return None

def start_webapp_api(config, host="0.0.0.0", port=5000, debug=False, background=True):
    """
    Start the webapp API server
    
    Args:
        config: Configuration dictionary
        host: Host to bind the server to
        port: Port to bind the server to
        debug: Whether to enable debug mode
        background: Whether to start in background
        
    Returns:
        The API server process if background=True, None otherwise
    """
    if not API_AVAILABLE:
        log_warning("API modules not available; cannot start webapp API server")
        return None
        
    # Prepare monitor configurations for the API server
    monitor_configs = {}
    
    # Add TPU monitor config if enabled
    tpu_config = config.get("tpu_monitor", {})
    if tpu_config.get("enabled", True):
        monitor_configs["tpu_monitor"] = tpu_config
    
    # Add Bucket monitor config if enabled
    bucket_config = config.get("bucket_monitor", {})
    if bucket_config.get("enabled", True):
        monitor_configs["bucket_monitor"] = bucket_config
    
    # Add Data transfer monitor config if enabled
    dt_config = config.get("data_transfer_monitor", {})
    if dt_config.get("enabled", True):
        monitor_configs["data_transfer_monitor"] = dt_config
    
    # Configure the API server
    configure(monitor_configs)
    
    # If background mode, start in a subprocess
    if background:
        api_cmd = [
            sys.executable, __file__, 
            "--api-only",
            "--host", host,
            "--port", str(port)
        ]
        if debug:
            api_cmd.append("--debug")
            
        try:
            process = subprocess.Popen(
                api_cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            log_success(f"Started webapp API server in background (PID: {process.pid})")
            log_success(f"API server will be accessible at http://{host}:{port}")
            return process
        except Exception as e:
            log_error(f"Error starting webapp API server: {e}")
            return None
    else:
        # Start the server directly
        log_success(f"Starting webapp API server on {host}:{port}")
        start_server(host=host, port=port, debug=debug)
        return None

def parse_args():
    """Parse command line arguments"""
    parser = argparse.ArgumentParser(description='Start web components for TPU monitoring system')
    
    # General configuration options
    parser.add_argument('--config', help='Path to configuration file (YAML)')
    parser.add_argument('--env', help='Path to environment file (.env)')
    parser.add_argument('--foreground', action='store_true', help='Run in foreground instead of background')
    
    # Component selection options
    parser.add_argument('--api-only', action='store_true', help='Start only the webapp API server')
    parser.add_argument('--tensorboard-only', action='store_true', help='Start only TensorBoard')
    
    # TensorBoard specific options
    parser.add_argument('--logdir', help='Directory containing TensorBoard logs (overrides config)')
    parser.add_argument('--tensorboard-host', default='0.0.0.0', help='Host to bind TensorBoard to')
    parser.add_argument('--tensorboard-port', type=int, default=6006, help='Port to bind TensorBoard to')
    
    # API server specific options
    parser.add_argument('--api-host', default='0.0.0.0', help='Host to bind the API server to')
    parser.add_argument('--api-port', type=int, default=5000, help='Port to bind the API server to')
    parser.add_argument('--debug', action='store_true', help='Enable debug mode for API server')
    
    return parser.parse_args()

def main():
    """Main entry point"""
    args = parse_args()
    
    # Load configuration
    config = get_config(args.config, args.env)
    
    if not config:
        log_warning("Failed to load configuration, using defaults")
    
    # Processes to keep track of
    processes = []
    
    # Handle API-only mode (direct server start)
    if args.api_only and API_AVAILABLE:
        # Configure and start API server
        monitor_configs = {}
        
        # Add TPU monitor config if enabled
        tpu_config = config.get("tpu_monitor", {})
        if tpu_config.get("enabled", True):
            monitor_configs["tpu_monitor"] = tpu_config
        
        # Add Bucket monitor config if enabled
        bucket_config = config.get("bucket_monitor", {})
        if bucket_config.get("enabled", True):
            monitor_configs["bucket_monitor"] = bucket_config
        
        # Add Data transfer monitor config if enabled
        dt_config = config.get("data_transfer_monitor", {})
        if dt_config.get("enabled", True):
            monitor_configs["data_transfer_monitor"] = dt_config
            
        # Configure and start API server
        configure(monitor_configs)
        start_server(host=args.api_host, port=args.api_port, debug=args.debug)
        return
        
    # Start TensorBoard if requested or if starting all components
    if not args.api_only:
        # Get log directory from args or config
        use_gcs = config.get("use_gcs", False)
        bucket_name = config.get("bucket_name", "")
        tensorboard_base = config.get("tensorboard_base", "tensorboard-logs/")
        
        if args.logdir:
            # Use explicitly provided log directory
            logdir = args.logdir
        elif use_gcs and bucket_name:
            # Use GCS path for logs
            logdir = f"gs://{bucket_name}/{tensorboard_base}"
            log_success(f"Using GCS path for TensorBoard logs: {logdir}")
        else:
            # Use local logs directory
            logdir = os.path.join("logs/tensorboard")
            if not os.path.exists(logdir):
                log_warning(f"Log directory {logdir} doesn't exist. Creating it.")
                os.makedirs(logdir, exist_ok=True)
        
        # Start TensorBoard
        tb_process = start_tensorboard(
            logdir=logdir,
            host=args.tensorboard_host,
            port=args.tensorboard_port,
            background=not args.foreground
        )
        
        if tb_process:
            processes.append(("tensorboard", tb_process))
    
    # Start API server if requested or if starting all components
    if not args.tensorboard_only:
        # Start API server
        api_process = start_webapp_api(
            config=config,
            host=args.api_host,
            port=args.api_port,
            debug=args.debug,
            background=not args.foreground
        )
        
        if api_process:
            processes.append(("api", api_process))
    
    # If no background processes were started or running in foreground, return
    if not processes or args.foreground:
        log_success("All components started in foreground mode or no components started")
        return
        
    # Print summary of started processes
    log_success(f"Started {len(processes)} components:")
    for name, process in processes:
        log_success(f"  - {name} (PID: {process.pid})")
    
    # Wait for keyboard interrupt
    try:
        log_success("Services running. Press Ctrl+C to stop all services.")
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        log("Stopping services by user request")
    finally:
        # Clean up all processes
        for name, process in processes:
            if process.poll() is None:  # If still running
                log(f"Stopping {name}...")
                process.terminate()
                try:
                    process.wait(timeout=5)
                    log_success(f"{name} stopped")
                except subprocess.TimeoutExpired:
                    log_warning(f"{name} did not stop gracefully, forcing termination")
                    process.kill()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("Stopped by user")
    except Exception as e:
        log_error(f"Error: {e}")
        sys.exit(1) 