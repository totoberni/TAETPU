#!/usr/bin/env python3
"""
Start the webapp API server for TPU monitoring system.
This provides a REST API to access monitoring data.
"""
import os
import sys
import argparse
from pathlib import Path

# Add the parent directory to the path to allow importing
parent_dir = Path(__file__).resolve().parent
if str(parent_dir) not in sys.path:
    sys.path.insert(0, str(parent_dir))

from dev.src.utils.logging.config_loader import get_config
from dev.src.utils.logging.cls_logging import log, log_success, log_warning, log_error
import webapp_api

def parse_args():
    """Parse command line arguments"""
    parser = argparse.ArgumentParser(description='Start the webapp API server for TPU monitoring')
    parser.add_argument('--config', help='Path to configuration file (YAML)')
    parser.add_argument('--env', help='Path to environment file (.env)')
    parser.add_argument('--host', default='0.0.0.0', help='Host to bind the server to')
    parser.add_argument('--port', type=int, default=5000, help='Port to bind the server to')
    parser.add_argument('--debug', action='store_true', help='Enable debug mode')
    return parser.parse_args()

def main():
    """Main entry point"""
    args = parse_args()
    
    # Load configuration
    config = get_config(args.config, args.env)
    
    if not config:
        log_warning("Failed to load configuration, using defaults")
    
    # Log the configuration
    webapp_config = config.get("webapp", {})
    log_success(f"Starting webapp API server with configuration: {webapp_config}")
    
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
    webapp_api.configure(monitor_configs)
    
    # Start the server
    log_success(f"Starting webapp API server on {args.host}:{args.port}")
    webapp_api.start_server(
        host=args.host,
        port=args.port,
        debug=args.debug
    )

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("Webapp API server stopped by user")
    except Exception as e:
        log_error(f"Error in webapp API server: {e}")
        sys.exit(1) 