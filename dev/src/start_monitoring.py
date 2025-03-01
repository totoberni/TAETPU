#!/usr/bin/env python3
"""
Unified TPU VM Monitoring and Dashboard System Entry Point

This script provides a centralized entry point for starting, stopping,
and managing monitoring services and dashboards for TPU VMs.

It can be used in three ways:
1. As a standalone script: python start_monitoring.py [action] [options]
2. As a module: from src.start_monitoring import start_monitoring
3. From another script: python -m src.start_monitoring [action] [options]

It merges functionality from the previously separate files:
- dev/src/monitor.py
- dev/src/utils/monitors/monitoring.py
- dev/src/utils/monitors/start_monitoring.py

This unified approach ensures full compatibility with existing tools
like run_example.sh while providing a cleaner architecture.
"""
import os
import sys
import argparse
import signal
import time
import threading
import subprocess
from pathlib import Path

# Add the parent directory to the path to allow importing
parent_dir = Path(__file__).resolve().parent.parent
if str(parent_dir) not in sys.path:
    sys.path.insert(0, str(parent_dir))

# Try to import logging utilities, with fallbacks
try:
    # First try import from utils.logging (relative import)
    from utils.logging.cls_logging import log, log_success, log_warning, log_error
    from utils.logging.config_loader import get_config, get_log_dir, get_tensorboard_dir, resolve_path, ensure_directory
    LOGGING_UTILS_AVAILABLE = True
except ImportError:
    try:
        # Then try with dev.src prefix (absolute import)
        from dev.src.utils.logging.cls_logging import log, log_success, log_warning, log_error
        from dev.src.utils.logging.config_loader import get_config, get_log_dir, get_tensorboard_dir, resolve_path, ensure_directory
        LOGGING_UTILS_AVAILABLE = True
    except ImportError:
        LOGGING_UTILS_AVAILABLE = False
        # Define simple fallback logging functions if not available
        def log(message): print(f"[INFO] {message}")
        def log_success(message): print(f"[SUCCESS] {message}")
        def log_warning(message): print(f"[WARNING] {message}")
        def log_error(message): print(f"[ERROR] {message}")
        # Simple config loader fallback
        def get_config(config_path=None): 
            return {} if config_path is None else {}
        # Simple path resolution
        def get_log_dir(config=None): return "logs"
        def get_tensorboard_dir(config=None): return os.environ.get("BUCKET_TENSORBOARD", "tensorboard-logs/")
        def resolve_path(path): return path
        def ensure_directory(directory): 
            os.makedirs(directory, exist_ok=True)
            return True

# Global variable to store monitor instances
monitors = {}

# Try to import monitor classes, with fallbacks
try:
    # First try import from utils.monitors (relative import)
    from utils.monitors.super_monitor import SuperMonitor
    from utils.monitors.tpu_monitor import TPUMonitor
    from utils.monitors.bucket_monitor import BucketMonitor
    MONITORS_AVAILABLE = True
except ImportError:
    try:
        # Then try with dev.src prefix (absolute import)
        from dev.src.utils.monitors.super_monitor import SuperMonitor
        from dev.src.utils.monitors.tpu_monitor import TPUMonitor
        from dev.src.utils.monitors.bucket_monitor import BucketMonitor
        MONITORS_AVAILABLE = True
    except ImportError:
        MONITORS_AVAILABLE = False
        log_warning("Monitor modules not available; monitoring features will be disabled")

# Try to import dashboard classes, with fallbacks
try:
    # First try import from utils.dashboards (relative import)
    from utils.dashboards.super_dashboard import Dashboard, SuperDashboard
    from utils.dashboards.tpu_dashboard import TPUDashboard
    from utils.dashboards.bucket_dashboard import BucketDashboard
    DASHBOARDS_AVAILABLE = True
except ImportError:
    try:
        # Then try with dev.src prefix (absolute import)
        from dev.src.utils.dashboards.super_dashboard import Dashboard, SuperDashboard
        from dev.src.utils.dashboards.tpu_dashboard import TPUDashboard
        from dev.src.utils.dashboards.bucket_dashboard import BucketDashboard
        DASHBOARDS_AVAILABLE = True
    except ImportError:
        DASHBOARDS_AVAILABLE = False
        log_warning("Dashboard modules not available; visualization features will be disabled")

# Try to import reporter (optional component)
try:
    from utils.reporter import Reporter
    REPORTER_AVAILABLE = True
except ImportError:
    try:
        from dev.src.utils.reporter import Reporter
        REPORTER_AVAILABLE = True
    except ImportError:
        REPORTER_AVAILABLE = False
        log_warning("Reporter module not available; reporting features will be disabled")

# Try to import API modules (optional component)
try:
    from dev.src.utils.api.webapp_api import configure, start_server
    from dev.src.utils.api.webapp_integration import configure_webapp_export, export_metrics_to_json
    API_AVAILABLE = True
except ImportError:
    try:
        from utils.api.webapp_api import configure, start_server
        from utils.api.webapp_integration import configure_webapp_export, export_metrics_to_json
        API_AVAILABLE = True
    except ImportError:
        API_AVAILABLE = False
        log_warning("API modules not available; webapp integration will be disabled")

def signal_handler(sig, frame):
    """Handle termination signals for graceful shutdown"""
    print("\nReceived termination signal, shutting down...")
    global monitors
    if monitors:
        for name, monitor in monitors.items():
            try:
                monitor.stop()
                print(f"{name.upper()} monitor stopped")
            except Exception as e:
                print(f"Error stopping {name} monitor: {e}")
    sys.exit(0)

def register_signal_handlers():
    """Register signal handlers for graceful shutdown"""
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

def start_webapp_api(config_path=None, env_path=None, background=True):
    """
    Start the webapp API server in a subprocess
    
    Args:
        config_path: Path to the config file
        env_path: Path to the .env file
        background: Whether to start in background (True) or wait for server (False)
    
    Returns:
        subprocess.Popen: The process object if background=True, None otherwise
    """
    # Check if API is available
    if not API_AVAILABLE:
        log_warning("Cannot start webapp API server - API modules not available")
        return None
    
    # Try to find the script path in different possible locations    
    script_paths = [
        os.path.join(parent_dir, "dev", "src", "utils", "api", "start_webapp.py"),
        os.path.join(parent_dir, "utils", "api", "start_webapp.py")
    ]
    
    script_path = None
    for path in script_paths:
        if os.path.exists(path):
            script_path = path
            break
    
    if not script_path:
        log_warning(f"Webapp API server script not found in expected locations")
        return None
        
    cmd = [sys.executable, script_path]
    
    if config_path:
        if not os.path.exists(config_path):
            log_warning(f"Config file not found at {config_path}")
        else:
            cmd.extend(["--config", config_path])
            
    if env_path:
        if not os.path.exists(env_path):
            log_warning(f"Env file not found at {env_path}")
        else:
            cmd.extend(["--env", env_path])
    
    try:
        if background:
            # Start in background
            process = subprocess.Popen(
                cmd, 
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True
            )
            log_success(f"Started webapp API server in background (PID: {process.pid})")
            return process
        else:
            # Start and wait for completion
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True
            )
            if result.returncode == 0:
                log_success("Webapp API server started successfully")
            else:
                log_error(f"Failed to start webapp API server: {result.stderr}")
            return None
    except Exception as e:
        log_error(f"Error starting webapp API server: {e}")
        return None

def start_monitoring(config_path=None, env_path=None, start_webapp=False, 
                log_dir=None, interval=None, bucket=None, port=None, dashboard=True):
    """
    Start the monitoring system with dashboards.
    
    Args:
        config_path: Path to configuration file (YAML)
        env_path: Path to .env file for environment variables
        start_webapp: Whether to start the web app
        log_dir: Directory for logs (overrides config)
        interval: Monitoring interval in seconds (overrides config)
        bucket: GCS bucket name (overrides config)
        port: Port for dashboard (overrides config)
        dashboard: Whether to start dashboards
        
    Returns:
        dict: Dictionary of started monitors
    """
    global monitors
    
    try:
        # Load configuration from log_config.yaml
        config = get_config(config_path, env_path)
        
        # Resolve log directory - prioritize command line arg, then config
        if log_dir is None:
            log_dir = get_log_dir(config)
        
        # Create log directory if needed
        ensure_directory(log_dir)
        
        # Create flag file to indicate monitoring initialization has started
        flag_file_tmp = os.path.join("/tmp", "monitoring_starting.flag")
        with open(flag_file_tmp, "w") as f:
            f.write(f"Monitoring starting at {time.strftime('%Y-%m-%d %H:%M:%S')}")
        
        # Update config with command line arguments (if provided)
        if interval is not None:
            # Try different possible locations in config
            if 'monitoring' in config:
                config['monitoring']['interval'] = interval
            elif 'tpu_monitor' in config:
                config['tpu_monitor']['sampling_interval'] = interval
            else:
                config['monitoring'] = {'interval': interval}
        else:
            # Get interval from config with fallbacks
            interval = (
                config.get('monitoring', {}).get('interval') or
                config.get('tpu_monitor', {}).get('sampling_interval') or
                30  # Default fallback
            )
        
        if bucket is not None:
            # Set bucket in config
            if 'storage' in config:
                config['storage']['bucket'] = bucket
            elif 'bucket_monitor' in config:
                config['bucket_monitor']['bucket_name'] = bucket
            else:
                # Try to get it from environment
                bucket = bucket or os.environ.get('BUCKET_NAME')
                config['storage'] = {'bucket': bucket}
        else:
            # Get bucket from config with fallbacks
            bucket = (
                config.get('storage', {}).get('bucket') or
                config.get('bucket_monitor', {}).get('bucket_name') or
                config.get('bucket_name') or
                os.environ.get('BUCKET_NAME')
            )
        
        if port is not None:
            # Set port in config
            if 'dashboard' in config:
                config['dashboard']['port'] = port
            else:
                config['dashboard'] = {'port': port}
        else:
            # Get port from config with fallback
            port = config.get('dashboard', {}).get('port', 8888)
        
        # Get TensorBoard directory from config (for monitors)
        tensorboard_dir = get_tensorboard_dir(config)
        
        # Set up monitoring directory
        monitoring_dir = os.path.join(log_dir, "monitoring")
        ensure_directory(monitoring_dir)
        
        # Get monitor-specific log directories from config
        tpu_log_dir = os.path.join(monitoring_dir, config.get('tpu_monitor', {}).get('log_dir', 'tpu'))
        bucket_log_dir = os.path.join(monitoring_dir, config.get('bucket_monitor', {}).get('log_dir', 'bucket'))
        ensure_directory(tpu_log_dir)
        ensure_directory(bucket_log_dir)
        
        # Get TensorBoard subdirectories for each monitor
        tpu_tb_dir = os.path.join(tensorboard_dir, config.get('tpu_monitor', {}).get('tb_log_dir', 'tpu'))
        bucket_tb_dir = os.path.join(tensorboard_dir, config.get('bucket_monitor', {}).get('tb_log_dir', 'bucket'))
        
        # Start monitors
        log("Starting monitoring system...")
        
        # Initialize monitors dictionary if needed
        monitors = {}
        
        # SuperMonitor combines all other monitors
        super_monitor = SuperMonitor(
            interval=int(interval),
            log_dir=monitoring_dir
        )
        monitors["super"] = super_monitor
        
        # TPU Monitor - use values from config
        tpu_monitor_enabled = config.get('tpu_monitor', {}).get('enabled', True)
        if tpu_monitor_enabled:
            tpu_monitor = TPUMonitor(
                interval=int(interval),
                log_dir=tpu_log_dir,
                tb_log_dir=tpu_tb_dir
            )
            monitors["tpu"] = tpu_monitor
            super_monitor.add_monitor(tpu_monitor)
        
        # Bucket Monitor - use values from config
        bucket_monitor_enabled = config.get('bucket_monitor', {}).get('enabled', True)
        if bucket_monitor_enabled and bucket:
            bucket_monitor = BucketMonitor(
                bucket_name=bucket,
                interval=int(interval),
                log_dir=bucket_log_dir,
                tb_log_dir=bucket_tb_dir
            )
            monitors["bucket"] = bucket_monitor
            super_monitor.add_monitor(bucket_monitor)
        
        # Start dashboards if requested
        if dashboard:
            log("Starting dashboards...")
            dashboards = {}
            
            # Import directly here to avoid circular references
            try:
                from utils.dashboards import start_dashboards
                dashboards = start_dashboards(
                    monitors, 
                    log_dir=os.path.join(log_dir, "dashboards"),
                    port=int(port),
                    config=config
                )
            except ImportError:
                try:
                    from dev.src.utils.dashboards import start_dashboards
                    dashboards = start_dashboards(
                        monitors, 
                        log_dir=os.path.join(log_dir, "dashboards"),
                        port=int(port),
                        config=config
                    )
                except ImportError:
                    log_error("Failed to import dashboard starter")
                    
                    # Create minimal dashboards manually
                    if "tpu" in monitors and tpu_monitor_enabled:
                        dashboards["tpu"] = TPUDashboard(
                            monitors["tpu"],
                            log_dir=os.path.join(log_dir, "dashboards", "tpu")
                        )
                    
                    if "bucket" in monitors and bucket_monitor_enabled:
                        dashboards["bucket"] = BucketDashboard(
                            monitors["bucket"],
                            log_dir=os.path.join(log_dir, "dashboards", "bucket")
                        )
            
            # Store dashboards in global variable for stop_monitoring
            globals()["dashboards"] = dashboards
        
        # Start all monitors
        for name, monitor in monitors.items():
            try:
                monitor.start()
                log_success(f"Started {name} monitor")
            except Exception as e:
                log_error(f"Failed to start {name} monitor: {e}")
        
        # Start web app if requested
        if start_webapp:
            try:
                from utils.api import start_server
                webapp_thread = threading.Thread(
                    target=start_server,
                    kwargs={
                        "monitors": monitors,
                        "port": config.get("webapp", {}).get("port", 5000),
                        "debug": False
                    }
                )
                webapp_thread.daemon = True
                webapp_thread.start()
                log_success("Started web app")
            except ImportError:
                log_warning("Web app module not available")
            except Exception as e:
                log_error(f"Failed to start web app: {e}")
        
        # Create flag files to indicate monitoring initialization is complete
        flag_file_logs = os.path.join(log_dir, "monitoring_ready.flag")
        flag_file_tmp_ready = os.path.join("/tmp", "monitoring_ready.flag")
        timestamp = time.strftime('%Y-%m-%d %H:%M:%S')
        
        # Write to both flag files
        for flag_file in [flag_file_logs, flag_file_tmp_ready]:
            try:
                with open(flag_file, "w") as f:
                    f.write(f"Monitoring initialized successfully at {timestamp}\n")
                    f.write(f"Active monitors: {', '.join(monitors.keys())}\n")
                    if dashboard and 'dashboards' in globals():
                        f.write(f"Active dashboards: {', '.join(globals()['dashboards'].keys())}\n")
                    f.write(f"Using configuration from: {config_path or 'default location'}\n")
                    f.write(f"Log directory: {log_dir}\n")
                    f.write(f"TensorBoard directory: {tensorboard_dir}\n")
            except Exception as e:
                log_warning(f"Failed to create flag file {flag_file}: {e}")
                
        # Remove the starting flag file if it exists
        if os.path.exists(flag_file_tmp):
            try:
                os.remove(flag_file_tmp)
            except Exception:
                pass
                
        log_success("Monitoring system started successfully")
        return monitors
        
    except Exception as e:
        log_error(f"Failed to start monitoring: {e}")
        import traceback
        log_error(traceback.format_exc())
        return {}

def stop_monitoring():
    """
    Stop all running monitors
    
    Returns:
        bool: True if successful, False otherwise
    """
    global monitors
    if not monitors:
        log_warning("No active monitors to stop")
        return False
    
    success = True
    for name, monitor in monitors.items():
        try:
            monitor.stop()
            log_success(f"{name.upper()} monitor stopped")
        except Exception as e:
            log_error(f"Error stopping {name} monitor: {e}")
            success = False
    
    monitors = {}
    return success

def generate_report(output_dir=None, format="html"):
    """
    Generate a monitoring report
    
    Args:
        output_dir: Directory for output files
        format: Report format (html, pdf, text)
        
    Returns:
        bool: True if successful, False otherwise
    """
    if not REPORTER_AVAILABLE:
        log_error("Reporter module not available. Cannot generate report.")
        return False
    
    try:
        log("Generating monitoring report...")
        
        # Load configuration to get proper paths
        config = get_config()
        
        # Resolve output directory
        if output_dir is None:
            log_dir = get_log_dir(config)
            output_dir = os.path.join(log_dir, "reports")
        
        # Ensure directory exists
        ensure_directory(output_dir)
        
        reporter = Reporter()
        reporter.generate_report(output_dir=output_dir, format=format)
        log_success(f"Report generated in {output_dir}")
        return True
    except Exception as e:
        log_error(f"Error generating report: {e}")
        return False

def main():
    """Main entry point for the monitoring system"""
    # Register signal handlers
    register_signal_handlers()
    
    # Set up argument parser
    parser = argparse.ArgumentParser(description="TPU VM Monitoring System")
    
    # Use subcommands for different actions
    subparsers = parser.add_subparsers(dest="action", help="Action to perform")
    
    # Start monitoring command
    start_parser = subparsers.add_parser("start", help="Start monitoring")
    start_parser.add_argument("--config", "-c", help="Path to configuration file")
    start_parser.add_argument("--env", "-e", help="Path to environment file")
    start_parser.add_argument("--log-dir", "-d", help="Directory for log files")
    start_parser.add_argument("--interval", "-i", type=int, help="Monitoring interval in seconds")
    start_parser.add_argument("--bucket", "-b", help="GCS bucket name")
    start_parser.add_argument("--port", "-p", type=int, help="Dashboard port")
    start_parser.add_argument("--webapp", "-w", action="store_true", help="Start webapp API server")
    start_parser.add_argument("--no-dashboard", action="store_true", help="Disable dashboards")
    
    # Stop monitoring command
    stop_parser = subparsers.add_parser("stop", help="Stop monitoring")
    
    # Generate report command
    report_parser = subparsers.add_parser("report", help="Generate monitoring report")
    report_parser.add_argument("--output-dir", "-o", help="Directory for output files")
    report_parser.add_argument("--format", "-f", choices=["html", "pdf", "text"], 
                            default="html", help="Report format")
    
    # Parse arguments
    args = parser.parse_args()
    
    if args.action == "start":
        # Start monitoring
        try:
            monitors = start_monitoring(
                config_path=args.config,
                env_path=args.env,
                start_webapp=args.webapp,
                log_dir=args.log_dir,
                interval=args.interval,
                bucket=args.bucket,
                port=args.port,
                dashboard=not args.no_dashboard
            )
            
            if not monitors:
                log_error("No monitors started. Check configuration and try again.")
                return 1
                
            log_success(f"Started {len(monitors)} monitors")
            
            # Keep running until interrupted
            try:
                while True:
                    time.sleep(1)
            except KeyboardInterrupt:
                log("Monitoring stopped by user")
                stop_monitoring()
        except Exception as e:
            log_error(f"Error starting monitoring: {e}")
            return 1
            
    elif args.action == "stop":
        # Stop monitoring
        if stop_monitoring():
            log_success("Monitoring stopped successfully")
            return 0
        else:
            log_error("Failed to stop monitoring")
            return 1
        
    elif args.action == "report":
        # Generate report
        if generate_report(args.output_dir, args.format):
            return 0
        else:
            return 1
    
    else:
        # If no action specified, show help
        parser.print_help()
        return 1
    
    return 0

if __name__ == "__main__":
    sys.exit(main()) 