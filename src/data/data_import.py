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
from pathlib import Path
from datasets import load_dataset, DatasetDict, Dataset, concatenate_datasets
from tqdm import tqdm

# Define the dataset directory (assuming we're running in the Docker container)
DATASET_DIR = "/app/mount/src/datasets/raw"

def parse_args():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(description="Download and process datasets for TPU experiments")
    parser.add_argument("--force", action="store_true", help="Force overwrite existing datasets without confirmation")
    parser.add_argument("--gutenberg-only", action="store_true", help="Only process the gutenberg dataset")
    parser.add_argument("--emotion-only", action="store_true", help="Only process the emotion dataset")
    return parser.parse_args()

def check_existing_datasets(force=False):
    """Check if datasets already exist and ask for permission to overwrite."""
    # Check if datasets already exist
    gutenberg_exists = os.path.exists(os.path.join(DATASET_DIR, "gutenberg"))
    emotion_exists = os.path.exists(os.path.join(DATASET_DIR, "emotion"))
    
    if gutenberg_exists or emotion_exists:
        existing = []
        if gutenberg_exists:
            existing.append("gutenberg")
        if emotion_exists:
            existing.append("emotion")
        
        print(f"Found existing datasets: {', '.join(existing)}")
        
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
    
    # Directory is expected to exist already, no need to check or create
    
    print("Checking for existing datasets...")
    should_continue = check_existing_datasets(args.force)
    
    if not should_continue:
        print("Operation cancelled.")
        return
    
    # Determine which datasets to process
    process_gutenberg = not args.emotion_only
    process_emotion = not args.gutenberg_only
    
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
    print(f"  - {os.path.join(DATASET_DIR, 'gutenberg')}")
    print(f"  - {os.path.join(DATASET_DIR, 'emotion')}")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nOperation cancelled by user.")
        sys.exit(1)