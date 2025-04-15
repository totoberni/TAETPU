import os
import json
from flask import Flask, jsonify, render_template
from datetime import datetime
import logging
from google.cloud import storage

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
tensorboard_path = os.environ.get('BUCKET_TENSORBOARD', 'tensorboard-logs/')

# Initialize GCS client
storage_client = storage.Client()

@app.route('/')
def index():
    """Simple index page with basic information"""
    return jsonify({
        'status': 'ok',
        'message': 'TAE-TPU Experiment Dashboard',
        'timestamp': datetime.now().isoformat()
    })

@app.route('/config')
def config():
    """Return the current configuration"""
    return jsonify({
        'project_id': project_id,
        'bucket_name': bucket_name,
        'tensorboard_path': tensorboard_path
    })

@app.route('/experiments')
def list_experiments():
    """List all experiment data from GCS bucket"""
    try:
        bucket = storage_client.get_bucket(bucket_name)
        # Get tensorboard logs path and list the experiment directories
        blobs = bucket.list_blobs(prefix=tensorboard_path.split('/')[-2])
        
        # Extract experiment names (directories)
        experiment_paths = set()
        for blob in blobs:
            # Get the experiment name (first directory after tensorboard_path)
            path = blob.name
            if path.endswith('/'):
                continue
                
            parts = path.split('/')
            if len(parts) > 1:
                experiment_paths.add(parts[1])  # Get first subdirectory
        
        return jsonify({
            'experiments': list(experiment_paths),
            'count': len(experiment_paths),
            'bucket': bucket_name,
            'updated_at': datetime.now().isoformat()
        })
    except Exception as e:
        logger.error(f"Error listing experiments: {str(e)}")
        return jsonify({
            'error': 'Failed to list experiments',
            'message': str(e)
        }), 500

@app.route('/experiments/<experiment_id>')
def get_experiment(experiment_id):
    """Get details for a specific experiment"""
    try:
        bucket = storage_client.get_bucket(bucket_name)
        prefix = f"{tensorboard_path.split('/')[-2]}/{experiment_id}/"
        
        # Get experiment files
        blobs = list(bucket.list_blobs(prefix=prefix))
        
        # Extract metadata
        files = [
            {
                'name': blob.name.split('/')[-1],
                'size': blob.size,
                'updated': blob.updated.isoformat(),
                'url': f"https://storage.googleapis.com/{bucket_name}/{blob.name}"
            }
            for blob in blobs if not blob.name.endswith('/')
        ]
        
        return jsonify({
            'experiment_id': experiment_id,
            'file_count': len(files),
            'files': files,
            'updated_at': datetime.now().isoformat()
        })
    except Exception as e:
        logger.error(f"Error getting experiment {experiment_id}: {str(e)}")
        return jsonify({
            'error': f'Failed to get experiment {experiment_id}',
            'message': str(e)
        }), 500

if __name__ == '__main__':
    # For local testing only
    port = int(os.environ.get('PORT', 8080))
    app.run(host='0.0.0.0', port=port, debug=os.environ.get('DEBUG', 'False').lower() == 'true') 