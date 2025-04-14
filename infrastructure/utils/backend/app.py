import os
import json
from flask import Flask, jsonify
from datetime import datetime
import logging

# Set up logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler("logs/backend.log"),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

# Initialize Flask app
app = Flask(__name__)

# Load environment variables
project_id = os.environ.get('PROJECT_ID', 'unknown')
bucket_name = os.environ.get('BUCKET_NAME', 'unknown')
tpu_name = os.environ.get('TPU_NAME', 'unknown')
tpu_zone = os.environ.get('TPU_ZONE', 'unknown')

@app.route('/')
def index():
    return jsonify({
        'status': 'ok',
        'message': 'TPU Monitoring Backend API',
        'timestamp': datetime.now().isoformat()
    })

@app.route('/config')
def config():
    """Return the current configuration"""
    return jsonify({
        'project_id': project_id,
        'bucket_name': bucket_name,
        'tpu_name': tpu_name,
        'tpu_zone': tpu_zone
    })

@app.route('/tpu/status')
def tpu_status():
    """Placeholder for TPU status endpoint"""
    # This would actually query the GCP API for real TPU status
    return jsonify({
        'tpu_name': tpu_name,
        'zone': tpu_zone,
        'status': 'RUNNING',  # placeholder
        'health': 'HEALTHY',  # placeholder
        'accelerator_type': 'v2-8',
        'updated_at': datetime.now().isoformat()
    })

@app.route('/bucket/status')
def bucket_status():
    """Placeholder for GCS bucket status endpoint"""
    # This would actually query the GCS API for real bucket info
    return jsonify({
        'bucket_name': bucket_name,
        'size': '1.2 GB',  # placeholder
        'object_count': 42,  # placeholder
        'last_updated': datetime.now().isoformat()
    })

@app.route('/docker/status')
def docker_status():
    """Placeholder for Docker image status endpoint"""
    return jsonify({
        'image_name': f'{project_id}/tae-tpu:v1',
        'created_at': '2023-03-10T10:00:00Z',  # placeholder
        'status': 'available',  # placeholder
        'size': '1.5 GB'  # placeholder
    })

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8080))
    app.run(host='0.0.0.0', port=port, debug=False) 