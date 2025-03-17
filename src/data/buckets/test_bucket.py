"""
test_bucket.py - Tests accessing the datasets from GCS based on YAML configuration.
"""
import argparse
import sys
import os
from google.cloud import storage

# Import from core and utils
from src.data.core import config_loader
from src.utils.data_utils import get_env_var

def main(bucket_name, config_path):
    # If bucket_name not provided, try to get from environment
    if not bucket_name:
        bucket_name = get_env_var("BUCKET_NAME")
        if not bucket_name:
            print("Error: BUCKET_NAME not provided and not found in environment")
            return 1
            
    bucket_uri = f"gs://{bucket_name}/datasets"
    
    # Load the datasets configuration
    datasets_config = config_loader.get_datasets_config(config_path)
    
    if not datasets_config:
        print("No datasets found in configuration file.")
        return 1
    
    print(f"Testing access to datasets in {bucket_uri}...")
    
    # Check if the datasets exist in the bucket
    client = storage.Client()
    bucket = client.bucket(bucket_name)
    
    # Test listing objects in the bucket for each dataset
    print(f"Listing objects in {bucket_uri}...")
    
    all_datasets_accessible = True
    
    for dataset_key in datasets_config.keys():
        dataset_prefix = f"datasets/{dataset_key}/"
        dataset_blobs = list(bucket.list_blobs(prefix=dataset_prefix, max_results=5))
        
        print(f"Found {len(dataset_blobs)} objects with prefix {dataset_prefix}")
        for blob in dataset_blobs[:3]:  # Show only first 3 for brevity
            print(f"  - {blob.name}")
        
        # Test loading dataset_info.json file to verify access
        try:
            print(f"\nVerifying access to {dataset_key} dataset files...")
            info_blob = bucket.blob(f"{dataset_prefix}dataset_info.json")
            content = info_blob.download_as_text()
            print(f"Successfully accessed {dataset_key} dataset info: {len(content)} bytes")
        except Exception as e:
            print(f"Error accessing {dataset_key} dataset from GCS: {e}")
            all_datasets_accessible = False
    
    if all_datasets_accessible:
        print("\nAll dataset access tests successful!")
        return 0
    else:
        print("\nSome datasets could not be accessed. See errors above.")
        return 1

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Test accessing datasets from GCS")
    parser.add_argument("--bucket-name", type=str, default="", 
                        help="Name of the GCS bucket containing the datasets (defaults to BUCKET_NAME env var)")
    parser.add_argument("--config-path", type=str, default=None,
                        help="Path to the data configuration YAML file")
    args = parser.parse_args()
    
    sys.exit(main(args.bucket_name, args.config_path))