"""
down_bucket.py - Downloads datasets from GCS to local storage for training based on YAML configuration.
"""
import os
import argparse
import sys
import json
import tempfile
import shutil
from datasets import load_from_disk
from google.cloud import storage

# Import from core and utils modules
from src.data.core import config_loader
from src.utils.data_utils import get_env_var, detect_environment

def download_from_gcs(bucket_name, source_path, destination_path):
    """Downloads a directory from GCS to local path."""
    client = storage.Client()
    bucket = client.bucket(bucket_name)
    
    # List all blobs with the prefix
    blobs = list(bucket.list_blobs(prefix=source_path))
    total_blobs = len(blobs)
    
    print(f"Found {total_blobs} files to download from gs://{bucket_name}/{source_path}")
    
    # Create local directories if they don't exist
    os.makedirs(destination_path, exist_ok=True)
    
    # Download each blob
    count = 0
    for blob in blobs:
        # Get the relative path of the file
        relative_path = blob.name[len(source_path):]
        if not relative_path:
            continue
            
        # Create the local file path
        local_path = os.path.join(destination_path, relative_path)
        
        # Create directory if it doesn't exist
        os.makedirs(os.path.dirname(local_path), exist_ok=True)
        
        # Download the blob
        blob.download_to_filename(local_path)
        count += 1
        if count % 10 == 0:
            print(f"Downloaded {count}/{total_blobs} files...")
    
    print(f"Downloaded {count} files from gs://{bucket_name}/{source_path} to {destination_path}")

def main(bucket_name, output_dir, config_path, dataset_keys=None, cleanup=True):
    # If bucket_name not provided, try to get from environment
    if not bucket_name:
        bucket_name = get_env_var("BUCKET_NAME")
        if not bucket_name:
            print("Error: BUCKET_NAME not provided and not found in environment")
            return 1
    
    # Create a temporary directory if output_dir is not specified
    temp_dir = None
    if output_dir is None:
        temp_dir = tempfile.mkdtemp(prefix="gcs_datasets_")
        output_dir = temp_dir
        print(f"Created temporary directory for datasets: {output_dir}")
    else:
        # Create output directory if it doesn't exist
        os.makedirs(output_dir, exist_ok=True)
    
    try:
        # Load the datasets configuration
        datasets_config = config_loader.get_datasets_config(config_path)
        
        if not datasets_config:
            print("No datasets found in configuration file.")
            return 1
        
        # If no specific datasets were requested, download all from config
        if dataset_keys is None:
            dataset_keys = config_loader.get_dataset_keys(config_path)
        else:
            # Verify the requested datasets exist in the config
            for key in dataset_keys[:]:  # Create a copy to avoid modifying during iteration
                if key not in datasets_config:
                    print(f"Warning: Dataset '{key}' not found in configuration, skipping.")
                    dataset_keys.remove(key)
        
        print(f"Downloading datasets from gs://{bucket_name}/datasets to {output_dir}...")
        
        for dataset_key in dataset_keys:
            gcs_path = f"datasets/{dataset_key}/"
            local_path = os.path.join(output_dir, dataset_key)
            
            print(f"Downloading {dataset_key} dataset from gs://{bucket_name}/{gcs_path}...")
            download_from_gcs(bucket_name, gcs_path, local_path)
            
            # Test loading the dataset
            try:
                dataset_obj = load_from_disk(local_path)
                print(f"Successfully loaded {dataset_key} dataset: {dataset_obj}")
            except Exception as e:
                print(f"Error loading {dataset_key} dataset: {e}")
        
        print("Dataset download complete.")
        return 0
    
    finally:
        # Clean up temporary directory if created and cleanup is requested
        if temp_dir and cleanup and os.path.exists(temp_dir):
            print(f"Cleaning up temporary directory: {temp_dir}")
            shutil.rmtree(temp_dir)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Download datasets from GCS")
    parser.add_argument("--bucket-name", type=str, default="", 
                        help="Name of the GCS bucket containing the datasets (defaults to BUCKET_NAME env var)")
    parser.add_argument("--output-dir", type=str, default=None, 
                        help="Directory to save the datasets (default: uses a temporary directory)")
    parser.add_argument("--config-path", type=str, default=None,
                        help="Path to the data configuration YAML file")
    parser.add_argument("--datasets", type=str, nargs="+", 
                        help="Specific datasets to download (default: all from config)")
    parser.add_argument("--no-cleanup", action="store_true",
                        help="Do not delete temporary directory after execution")
    args = parser.parse_args()
    
    sys.exit(main(args.bucket_name, args.output_dir, args.config_path, args.datasets, not args.no_cleanup))