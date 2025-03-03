# src/backend/tensorboard/server.py
from flask import Flask, jsonify, request, redirect
import os
import json
import subprocess
import requests
from google.cloud import storage
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

app = Flask(__name__)

# Configuration from environment
BUCKET_NAME = os.environ.get('BUCKET_NAME', 'infra-tempo-401122-hello-world-bucket')
TENSORBOARD_LOG_DIR = os.environ.get('TENSORBOARD_LOG_DIR', 'tensorboard-logs')
TENSORBOARD_PORT = os.environ.get('TENSORBOARD_PORT', '6006')
TENSORBOARD_HOST = os.environ.get('TENSORBOARD_HOST', '0.0.0.0')

@app.route('/')
def index():
    """Redirect to TensorBoard UI"""
    # Redirect to TensorBoard running on internal port
    return redirect(f'http://{TENSORBOARD_HOST}:{TENSORBOARD_PORT}')

@app.route('/api/status')
def status():
    """Get server status"""
    return jsonify({
        'status': 'ok',
        'bucket': BUCKET_NAME,
        'log_dir': TENSORBOARD_LOG_DIR,
        'tensorboard_url': f'http://{TENSORBOARD_HOST}:{TENSORBOARD_PORT}'
    })

@app.route('/api/logs')
def get_logs():
    """Get list of available log directories"""
    try:
        client = storage.Client()
        bucket = client.get_bucket(BUCKET_NAME)
        
        # List directories in the TensorBoard log path
        blobs = bucket.list_blobs(prefix=TENSORBOARD_LOG_DIR)
        
        # Extract unique subdirectories
        dirs = set()
        for blob in blobs:
            path = blob.name.replace(TENSORBOARD_LOG_DIR, '').strip('/')
            if '/' in path:
                # Get the top-level directory
                dirs.add(path.split('/')[0])
        
        return jsonify({
            'status': 'ok',
            'log_directories': sorted(list(dirs))
        })
    except Exception as e:
        return jsonify({
            'status': 'error',
            'error': str(e)
        }), 500

@app.route('/api/metrics')
def get_metrics():
    """Get latest metrics from all monitors"""
    try:
        client = storage.Client()
        bucket = client.get_bucket(BUCKET_NAME)
        
        # Check for metrics files from different monitors
        metrics = {}
        
        monitor_dirs = ['tpu', 'bucket', 'super']
        for monitor in monitor_dirs:
            metrics_path = f"{TENSORBOARD_LOG_DIR}/{monitor}/latest_metrics.json"
            blob = bucket.blob(metrics_path)
            
            if blob.exists():
                content = blob.download_as_text()
                metrics[monitor] = json.loads(content)
        
        return jsonify({
            'status': 'ok',
            'metrics': metrics
        })
    except Exception as e:
        return jsonify({
            'status': 'error',
            'error': str(e)
        }), 500

if __name__ == '__main__':
    # For local development only
    app.run(host=TENSORBOARD_HOST, port=int(os.environ.get('PORT', 8080)))