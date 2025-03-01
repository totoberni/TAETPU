"""
Flask API server for the TPU monitoring system.
Provides HTTP endpoints to access monitoring data in JSON format.
"""
from flask import Flask, jsonify, request
import os
import json
from datetime import datetime
import logging
import threading
import time
from typing import Dict, List, Any

# Initialize Flask app
app = Flask(__name__)

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Dictionary to store the latest metrics from all monitors
latest_metrics: Dict[str, Dict[str, Any]] = {}
last_update_time: Dict[str, datetime] = {}
monitors_config = {}

# Background thread to read metrics files
def metrics_reader():
    """Background thread that reads metrics files from all monitors"""
    global latest_metrics, last_update_time
    
    logger.info("Starting metrics reader thread")
    while True:
        try:
            # Check if log directories are configured
            if not monitors_config:
                time.sleep(5)
                continue
                
            # For each configured monitor
            for monitor_name, monitor_config in monitors_config.items():
                log_dir = monitor_config.get("log_dir", "")
                if not log_dir or not os.path.exists(log_dir):
                    continue
                    
                # Look for latest_metrics.json file
                metrics_file = os.path.join(log_dir, "latest_metrics.json")
                if not os.path.exists(metrics_file):
                    continue
                    
                # Get file modification time
                mod_time = os.path.getmtime(metrics_file)
                file_mod_time = datetime.fromtimestamp(mod_time)
                
                # If file hasn't been updated since last check, skip
                if monitor_name in last_update_time and file_mod_time <= last_update_time[monitor_name]:
                    continue
                
                # Read the metrics file
                try:
                    with open(metrics_file, 'r') as f:
                        metrics_data = json.load(f)
                        
                    # Store in our cache
                    latest_metrics[monitor_name] = metrics_data
                    last_update_time[monitor_name] = file_mod_time
                    logger.info(f"Updated metrics for {monitor_name}")
                except Exception as e:
                    logger.error(f"Error reading metrics for {monitor_name}: {e}")
            
            # Sleep before next check
            time.sleep(5)
        except Exception as e:
            logger.error(f"Error in metrics reader thread: {e}")
            time.sleep(10)

# API Routes
@app.route('/api/metrics', methods=['GET'])
def get_all_metrics():
    """Get metrics from all monitors"""
    return jsonify({
        "timestamp": datetime.now().isoformat(),
        "monitors": latest_metrics
    })

@app.route('/api/metrics/<monitor_name>', methods=['GET'])
def get_monitor_metrics(monitor_name):
    """Get metrics for a specific monitor"""
    if monitor_name in latest_metrics:
        return jsonify(latest_metrics[monitor_name])
    else:
        return jsonify({"error": f"Monitor '{monitor_name}' not found"}), 404

@app.route('/api/status', methods=['GET'])
def get_status():
    """Get overall system status"""
    status = "healthy"
    issues = []
    
    # Check if we have any metrics at all
    if not latest_metrics:
        status = "no_data"
        issues.append("No metrics available")
    
    # Check if any monitor is reporting a non-ok status
    for monitor_name, data in latest_metrics.items():
        if data.get("status", "ok") != "ok":
            status = "warning"
            issues.append(f"{monitor_name}: {data.get('status')}")
    
    return jsonify({
        "timestamp": datetime.now().isoformat(),
        "status": status,
        "issues": issues,
        "monitors": list(latest_metrics.keys())
    })

def configure(config):
    """Configure the API with the monitor configurations"""
    global monitors_config
    
    # Store configurations for later use
    for monitor_name, monitor_config in config.items():
        if isinstance(monitor_config, dict) and "log_dir" in monitor_config:
            monitors_config[monitor_name] = monitor_config
    
    # Start the metrics reader thread
    reader_thread = threading.Thread(target=metrics_reader, daemon=True)
    reader_thread.start()
    
    return True

def start_server(host="0.0.0.0", port=5000, debug=False):
    """Start the Flask server"""
    logger.info(f"Starting webapp API server on {host}:{port}")
    app.run(host=host, port=port, debug=debug)

if __name__ == "__main__":
    # Example configuration
    example_config = {
        "tpu_monitor": {
            "log_dir": "./logs/tpu_monitor",
        },
        "bucket_monitor": {
            "log_dir": "./logs/bucket_monitor",
        }
    }
    
    # Configure and start
    configure(example_config)
    start_server(debug=True) 