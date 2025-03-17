"""
import_data.py - Downloads datasets from Hugging Face based on YAML configuration.
"""
import os
import argparse
import sys
from datasets import load_dataset

# Import from core and utils modules
from src.data.core import config_loader
from src.utils.data_utils import get_env_var, detect_environment

def main(output_dir, config_path):
    # If no output directory is specified, get the default
    if output_dir is None:
        env_info = detect_environment()
        output_dir = env_info['output_dir']
    
    # Create output directory if it doesn't exist
    os.makedirs(output_dir, exist_ok=True)
    
    # Load the configuration
    datasets_config = config_loader.get_datasets_config(config_path)
    
    if not datasets_config:
        print("No datasets found in configuration file.")
        return 1
    
    print(f"Downloading datasets to {output_dir}...")
    
    # Process each dataset in the configuration
    for dataset_key, dataset_info in datasets_config.items():
        dataset_name = dataset_info.get('name')
        if not dataset_name:
            print(f"Warning: Dataset '{dataset_key}' has no 'name' field, skipping.")
            continue
        
        print(f"Downloading {dataset_name} dataset...")
        dataset = load_dataset(dataset_name)
        output_path = os.path.join(output_dir, dataset_key)
        dataset.save_to_disk(output_path)
        print(f"Saved {dataset_key} dataset to {output_path}")
    
    print("Dataset download complete.")
    return 0

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Download datasets from Hugging Face")
    parser.add_argument("--output-dir", type=str, default=None, 
                        help="Directory to save the datasets (default: auto-detected based on environment)")
    parser.add_argument("--config-path", type=str, default=None,
                        help="Path to the data configuration YAML file")
    args = parser.parse_args()
    
    sys.exit(main(args.output_dir, args.config_path))