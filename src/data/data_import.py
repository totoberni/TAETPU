"""
Data import script for downloading and processing datasets for TPU experiments.

This script downloads specified datasets from HuggingFace and processes them
into a standardized format for use in TPU experiments.

Usage:
  python data_import.py [--force] [--gutenberg-only] [--emotion-only]

Options:
  --force           Force overwrite existing datasets without confirmation
  --gutenberg-only  Only process the gutenberg dataset
  --emotion-only    Only process the emotion dataset
"""
import os
import sys
import argparse
import yaml
from pathlib import Path
from datasets import load_dataset, DatasetDict, Dataset, concatenate_datasets
from tqdm import tqdm

# Define the dataset directory (mounted from tae_datasets volume)
DATASET_DIR = "/app/mount/src/datasets/raw"
CONFIG_PATH = "/app/mount/src/configs/data_config.yaml"

def load_config(config_path=CONFIG_PATH):
    """Load data configuration from YAML file."""
    try:
        with open(config_path, 'r') as f:
            config = yaml.safe_load(f)
        return config
    except Exception as e:
        print(f"Error loading configuration: {e}")
        return None

def get_available_datasets(config):
    """Get the list of datasets defined in the configuration."""
    if not config or 'datasets' not in config:
        return []
    return list(config['datasets'].keys())

def ensure_dataset_dirs(datasets):
    """Ensure dataset directories exist in raw/ directory."""
    for dataset_name in datasets:
        dataset_path = os.path.join(DATASET_DIR, dataset_name)
        os.makedirs(dataset_path, exist_ok=True)

def parse_args():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(description="Download and process datasets for TPU experiments")
    parser.add_argument("--force", action="store_true", help="Force overwrite existing datasets without confirmation")
    parser.add_argument("--gutenberg-only", action="store_true", help="Only process the gutenberg dataset")
    parser.add_argument("--emotion-only", action="store_true", help="Only process the emotion dataset")
    parser.add_argument("--config", type=str, default=CONFIG_PATH, help="Path to data configuration file")
    return parser.parse_args()

def check_existing_datasets(force=False):
    """Check if datasets already exist and ask for permission to overwrite."""
    # Load configuration to get all dataset names
    config = load_config()
    if not config:
        print("Failed to load configuration. Cannot determine available datasets.")
        return False
        
    available_datasets = get_available_datasets(config)
    
    # Check if datasets already exist
    existing_datasets = []
    for dataset_name in available_datasets:
        dataset_path = os.path.join(DATASET_DIR, dataset_name)
        if os.path.exists(dataset_path) and os.path.isdir(dataset_path) and any(os.listdir(dataset_path)):
            existing_datasets.append(dataset_name)
    
    if existing_datasets:
        print(f"Found existing datasets: {', '.join(existing_datasets)}")
        
        if force:
            print("Force flag set. Overwriting existing datasets.")
            return True
        
        try:
            response = input("Do you want to overwrite these datasets? (y/n): ").strip().lower()
            return response == 'y'
        except (KeyboardInterrupt, EOFError):
            print("\nOperation cancelled by user.")
            return False
    
    return True

def process_gutenberg_dataset():
    """Load and process the gutenberg dataset."""
    print("Loading gutenberg dataset...")
    try:
        # Load the dataset
        gutenberg = load_dataset("nbeerbower/gutenberg2-dpo")
        
        print("Processing gutenberg dataset...")
        # Extract only the 'chosen' column from the train split
        # Create a new dataset with only the chosen column
        processed_dataset = gutenberg["train"].remove_columns(
            [col for col in gutenberg["train"].column_names if col != "chosen"]
        )
        
        # Create DatasetDict with 'unsplit' key
        processed_dict = DatasetDict({"unsplit": processed_dataset})
        
        print(f"Gutenberg dataset processed. Total examples: {len(processed_dataset)}")
        return processed_dict
    
    except Exception as e:
        print(f"Error processing gutenberg dataset: {e}")
        raise

def process_emotion_dataset():
    """Load and process the emotion dataset."""
    print("Loading emotion dataset...")
    try:
        # Load the dataset
        emotion = load_dataset("dair-ai/emotion")
        
        print("Processing emotion dataset...")
        # Prepare datasets from all splits with renamed column
        renamed_splits = []
        
        for split in emotion:
            # Rename 'label' to 'emo_label'
            split_data = emotion[split].rename_column("label", "emo_label")
            renamed_splits.append(split_data)
        
        # Concatenate all splits into one dataset
        print("Merging emotion dataset splits...")
        merged_dataset = concatenate_datasets(renamed_splits)
        
        # Create DatasetDict with 'unsplit' key
        processed_dict = DatasetDict({"unsplit": merged_dataset})
        
        print(f"Emotion dataset processed. Total examples: {len(merged_dataset)}")
        return processed_dict
    
    except Exception as e:
        print(f"Error processing emotion dataset: {e}")
        raise

def save_dataset(dataset, name):
    """Save the processed dataset to the specified directory."""
    dataset_path = os.path.join(DATASET_DIR, name)
    os.makedirs(dataset_path, exist_ok=True)
    print(f"Saving processed dataset to {dataset_path}")
    
    try:
        dataset.save_to_disk(dataset_path)
        print(f"Dataset '{name}' saved successfully.")
    except Exception as e:
        print(f"Error saving dataset '{name}': {e}")
        raise

def main():
    """Main function to download and process datasets."""
    args = parse_args()
    
    # Load configuration
    config = load_config(args.config)
    if not config:
        print("Failed to load configuration. Exiting.")
        return
    
    # Get all datasets from configuration
    all_datasets = get_available_datasets(config)
    if not all_datasets:
        print("No datasets defined in configuration.")
        return
    
    # Ensure raw dataset directories exist
    ensure_dataset_dirs(all_datasets)
    
    # Check for existing datasets
    print("Checking for existing datasets...")
    should_continue = check_existing_datasets(args.force)
    
    if not should_continue:
        print("Operation cancelled.")
        return
    
    # Determine which datasets to process
    process_gutenberg = not args.emotion_only and "gutenberg" in all_datasets
    process_emotion = not args.gutenberg_only and "emotion" in all_datasets
    
    # Process and save datasets
    if process_gutenberg:
        try:
            print("\n=== Processing Gutenberg Dataset ===")
            gutenberg_processed = process_gutenberg_dataset()
            save_dataset(gutenberg_processed, "gutenberg")
            print("Gutenberg dataset processing complete.")
        except Exception as e:
            print(f"Failed to process gutenberg dataset: {e}")
    
    if process_emotion:
        try:
            print("\n=== Processing Emotion Dataset ===")
            emotion_processed = process_emotion_dataset()
            save_dataset(emotion_processed, "emotion")
            print("Emotion dataset processing complete.")
        except Exception as e:
            print(f"Failed to process emotion dataset: {e}")
    
    print("\nDataset import and processing complete.")
    print("Datasets available at:")
    for dataset in all_datasets:
        if (dataset == "gutenberg" and process_gutenberg) or (dataset == "emotion" and process_emotion):
            print(f"  - {os.path.join(DATASET_DIR, dataset)}")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nOperation cancelled by user.")
        sys.exit(1)