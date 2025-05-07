"""
Data Pipeline Entry Point for Transformer Ablation Experiments.

This module serves as the main entry point for preprocessing data for transformer
ablation experiments. It handles command-line arguments and coordinates the
different preprocessing stages with TPU optimization.
"""

import os
import sys
import argparse
import logging
import time
from typing import Dict, List, Optional, Any, Union
import torch
import numpy as np
from tqdm import tqdm

# Import from reorganized package
from .utils.processing import load_config, ensure_directories_exist, optimize_for_tpu
from .utils.data_io import load_dataset
from .processors.transformer import TransformerProcessor
from .processors.static import StaticProcessor
from .types import TransformerInput, TransformerTarget, StaticInput, StaticTarget, TaskLabels

# Constants - paths are mounted via Docker volumes
CONFIG_PATH = "/app/mount/src/configs/data_config.yaml"
DATASET_RAW_DIR = "/app/mount/src/datasets/raw"
DATASET_CLEAN_DIR = "/app/mount/src/datasets/clean"
CACHE_PREP_DIR = "/app/mount/src/cache/prep"
MODELS_PREP_DIR = "/app/mount/src/models/prep"

# Setup logging
logger = logging.getLogger('data_pipeline')
logging.basicConfig(level=logging.INFO, 
                    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')

def parse_args() -> argparse.Namespace:
    """Parse command-line arguments for the data pipeline."""
    parser = argparse.ArgumentParser(description="Data Pipeline for TPU-optimized Transformer Ablation Experiments")
    
    # Main operation modes
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument("--download", action="store_true", help="Download and prepare raw datasets")
    mode_group.add_argument("--preprocess", action="store_true", help="Preprocess datasets (default if no mode specified)")
    mode_group.add_argument("--view", action="store_true", help="View datasets")
    
    # Model and dataset selection
    parser.add_argument("--model", type=str, choices=["transformer", "static", "all"],
                      default="all", help="Model type to preprocess data for")
    parser.add_argument("--dataset", type=str, help="Dataset to preprocess (comma-separated for multiple)")
    
    # Dataset viewing options
    parser.add_argument("--dataset-type", type=str, choices=["raw", "clean", "auto"],
                      default="auto", help="Type of datasets to view")
    parser.add_argument("--examples", type=int, default=3, help="Number of examples to show")
    parser.add_argument("--detailed", action="store_true", help="Show detailed information")
    
    # Resource configuration
    parser.add_argument("--config", type=str, default=CONFIG_PATH, help="Path to config YAML file")
    parser.add_argument("--output-dir", type=str, default=DATASET_CLEAN_DIR, help="Output directory")
    parser.add_argument("--cache-dir", type=str, default=CACHE_PREP_DIR, help="Cache directory")
    parser.add_argument("--raw-dir", type=str, default=DATASET_RAW_DIR, help="Raw datasets directory")
    
    # Processing options
    parser.add_argument("--force", action="store_true", help="Force overwrite existing data")
    parser.add_argument("--disable-cache", action="store_true", help="Disable caching")
    parser.add_argument("--n-processes", type=int, default=None, help="Number of processes")
    parser.add_argument("--optimize-for-tpu", action="store_true", help="Optimize for TPU")
    parser.add_argument("--profile", action="store_true", help="Enable performance profiling")
    
    return parser.parse_args()

def download_datasets(config: Dict, force: bool = False) -> bool:
    """
    Download and prepare raw datasets.
    
    Args:
        config: Configuration dictionary
        force: Whether to force download even if dataset exists
    
    Returns:
        True if successful, False otherwise
    """
    from datasets import load_dataset
    
    logger.info("Starting dataset download stage")
    ensure_directories_exist([DATASET_RAW_DIR])
    
    # Extract dataset configurations
    if 'datasets' not in config:
        logger.error("No datasets defined in configuration")
        return False
    
    datasets_config = config['datasets']
    success = True
    
    for dataset_name, dataset_config in datasets_config.items():
        dataset_path = os.path.join(DATASET_RAW_DIR, dataset_name)
        
        # Skip if dataset exists and force is False
        if os.path.exists(dataset_path) and not force:
            logger.info(f"Dataset {dataset_name} already exists. Use --force to overwrite.")
            continue
        
        logger.info(f"Downloading dataset: {dataset_name}")
        try:
            # Handle different dataset sources
            if dataset_name == "gutenberg":
                dataset = load_dataset("nbeerbower/gutenberg2-dpo")
                # Keep only the 'chosen' column
                dataset = dataset.remove_columns([c for c in dataset["train"].column_names if c != "chosen"])
            elif dataset_name == "emotion":
                dataset = load_dataset("dair-ai/emotion")
                # Rename 'label' to 'emo_label' for clarity
                dataset = dataset.rename_column("label", "emo_label")
            else:
                # Generic dataset loading using config
                hf_name = dataset_config.get('name', dataset_name)
                dataset = load_dataset(hf_name)
            
            # Save dataset to disk
            os.makedirs(dataset_path, exist_ok=True)
            dataset.save_to_disk(dataset_path)
            logger.info(f"Successfully downloaded and saved dataset: {dataset_name}")
            
        except Exception as e:
            logger.error(f"Error downloading dataset {dataset_name}: {e}")
            success = False
    
    return success

def view_datasets(args: argparse.Namespace, config: Dict) -> None:
    """
    View datasets in raw or processed format.
    
    Args:
        args: Command-line arguments
        config: Configuration dictionary
    """
    from datasets import load_from_disk
    from transformers import AutoTokenizer
    
    # Determine dataset type if 'auto'
    dataset_type = args.dataset_type
    if dataset_type == 'auto':
        clean_exists = os.path.exists(args.output_dir) and len(os.listdir(args.output_dir)) > 0
        raw_exists = os.path.exists(args.raw_dir) and len(os.listdir(args.raw_dir)) > 0
        
        if clean_exists:
            dataset_type = 'clean'
        elif raw_exists:
            dataset_type = 'raw'
        else:
            logger.error("No datasets found in either raw or clean directories")
            return
    
    logger.info(f"Viewing {dataset_type} datasets")
    
    # Determine which datasets to view
    available_datasets = []
    if dataset_type == 'raw':
        available_datasets = [d for d in os.listdir(args.raw_dir) 
                             if os.path.isdir(os.path.join(args.raw_dir, d))]
    else:  # clean
        model_types = ["transformer", "static"] if args.model == "all" else [args.model]
        for model_type in model_types:
            model_dir = os.path.join(args.output_dir, model_type)
            if os.path.exists(model_dir):
                model_datasets = [d for d in os.listdir(model_dir) 
                                if os.path.isdir(os.path.join(model_dir, d))]
                available_datasets.extend(model_datasets)
        available_datasets = list(set(available_datasets))  # Remove duplicates
    
    # Filter datasets if specified
    if args.dataset:
        requested_datasets = args.dataset.split(',')
        available_datasets = [d for d in available_datasets if d in requested_datasets]
    
    if not available_datasets:
        logger.info(f"No {dataset_type} datasets found")
        return
    
    logger.info(f"Available {dataset_type} datasets: {available_datasets}")
    
    # View each dataset
    for dataset_name in available_datasets:
        if dataset_type == 'raw':
            # View raw dataset
            dataset_path = os.path.join(args.raw_dir, dataset_name)
            try:
                dataset = load_from_disk(dataset_path)
                logger.info(f"{'='*50}")
                logger.info(f"Raw Dataset: {dataset_name}")
                logger.info(f"{'='*50}")
                
                for split in dataset:
                    logger.info(f"Split: {split}, Examples: {len(dataset[split])}")
                    logger.info(f"Columns: {dataset[split].column_names}")
                    
                    # Show examples
                    if args.examples > 0:
                        for i, example in enumerate(dataset[split].select(range(min(args.examples, len(dataset[split]))))):
                            logger.info(f"Example {i+1}:")
                            for column in dataset[split].column_names:
                                value = example[column]
                                if isinstance(value, str) and len(value) > 100:
                                    value = value[:100] + "..."
                                logger.info(f"  {column}: {value}")
            except Exception as e:
                logger.error(f"Error viewing dataset {dataset_name}: {e}")
                
        else:  # clean
            # View processed datasets
            model_types = ["transformer", "static"] if args.model == "all" else [args.model]
            
            for model_type in model_types:
                dataset_path = os.path.join(args.output_dir, model_type, dataset_name)
                if not os.path.exists(dataset_path):
                    continue
                
                logger.info(f"{'='*50}")
                logger.info(f"{model_type.capitalize()} Dataset: {dataset_name}")
                logger.info(f"{'='*50}")
                
                # Load inputs and targets
                inputs_path = os.path.join(dataset_path, "inputs.pt")
                targets_path = os.path.join(dataset_path, "targets.pt")
                
                if os.path.exists(inputs_path) and os.path.exists(targets_path):
                    try:
                        inputs = torch.load(inputs_path)
                        targets = torch.load(targets_path)
                        
                        logger.info(f"Number of examples: {len(inputs)}")
                        
                        # For transformer, show tokenizer info
                        if model_type == 'transformer':
                            tokenizer_path = os.path.join(dataset_path, "tokenizer")
                            if os.path.exists(tokenizer_path):
                                tokenizer = AutoTokenizer.from_pretrained(tokenizer_path)
                                logger.info(f"Tokenizer vocabulary size: {tokenizer.vocab_size}")
                        
                        # Show examples
                        if args.examples > 0:
                            for i in range(min(args.examples, len(inputs))):
                                logger.info(f"Example {i+1}:")
                                
                                if model_type == 'transformer':
                                    logger.info(f"  Input shape: {inputs[i].input_ids.shape}")
                                    if args.detailed and 'tokenizer' in locals():
                                        input_text = tokenizer.decode(
                                            inputs[i].input_ids[inputs[i].attention_mask.astype(bool)]
                                        )
                                        if len(input_text) > 100:
                                            input_text = input_text[:100] + "..."
                                        logger.info(f"  Text: {input_text}")
                                else:  # static
                                    logger.info(f"  Center Words shape: {inputs[i].center_words.shape}")
                                    logger.info(f"  Context Words shape: {inputs[i].context_words.shape}")
                                
                                # Show task labels
                                if hasattr(targets[i], 'task_labels') and targets[i].task_labels:
                                    logger.info("  Task Labels:")
                                    for task, labels in targets[i].task_labels.items():
                                        logger.info(f"    {task}: {labels.labels.shape}")
                                
                                # Show metadata for detailed view
                                if args.detailed and hasattr(inputs[i], 'metadata') and inputs[i].metadata:
                                    logger.info("  Metadata:")
                                    for key, value in inputs[i].metadata.items():
                                        if key in ['word_ids', 'alignment_map']:
                                            logger.info(f"    {key}: [Array of length {len(value) if value is not None else 0}]")
                                        elif isinstance(value, str) and len(value) > 100:
                                            logger.info(f"    {key}: {value[:100]}...")
                                        else:
                                            logger.info(f"    {key}: {value}")
                    
                    except Exception as e:
                        logger.error(f"Error viewing processed dataset {dataset_name}: {e}")
                        
                # Check TPU-optimized datasets
                if args.detailed:
                    tpu_dir = os.path.join(dataset_path, "tpu_optimized")
                    if os.path.exists(tpu_dir):
                        logger.info(f"{'='*50}")
                        logger.info(f"TPU-Optimized {model_type.capitalize()} Dataset: {dataset_name}")
                        logger.info(f"{'='*50}")
                        
                        files = [f for f in os.listdir(tpu_dir) if f.endswith('.npy')]
                        logger.info(f"Available TPU-optimized arrays: {files}")

def preprocess_datasets(args: argparse.Namespace, config: Dict) -> None:
    """
    Preprocess datasets for transformer and static embedding models.
    
    Args:
        args: Command-line arguments
        config: Configuration dictionary
    """
    logger.info("Starting preprocessing stage")
    
    # Ensure required directories exist
    dirs_to_create = [
        args.output_dir,
        args.cache_dir,
        os.path.join(args.output_dir, 'transformer'),
        os.path.join(args.output_dir, 'static')
    ]
    ensure_directories_exist(dirs_to_create)
    
    # Get datasets to process
    all_datasets = list(config.get('datasets', {}).keys())
    if args.dataset:
        datasets_to_process = args.dataset.split(',')
        for dataset in datasets_to_process:
            if dataset not in all_datasets:
                logger.warning(f"Dataset '{dataset}' not defined in configuration")
    else:
        datasets_to_process = all_datasets
    
    # Get model types to process
    model_types = []
    if args.model == "all":
        model_types = ["transformer", "static"]
    else:
        model_types = [args.model]
    
    # Start profiling if requested
    if args.profile:
        start_time = time.time()
    
    # Create processor instances
    transformer_processor = None
    if "transformer" in model_types:
        transformer_processor = TransformerProcessor()
    
    static_processor = None
    if "static" in model_types:
        static_processor = StaticProcessor()
    
    # Process datasets
    transformer_results = {}
    
    # Process transformer datasets
    if transformer_processor:
        logger.info("Processing transformer datasets")
        for dataset_name in datasets_to_process:
            try:
                logger.info(f"Processing transformer dataset: {dataset_name}")
                result = transformer_processor.process_dataset(
                    dataset_name=dataset_name,
                    config=config,
                    output_dir=os.path.join(args.output_dir, 'transformer'),
                    cache_dir=None if args.disable_cache else args.cache_dir,
                    force=args.force,
                    n_processes=args.n_processes
                )
                transformer_results[dataset_name] = result
            except Exception as e:
                logger.error(f"Error processing transformer dataset {dataset_name}: {e}")
    
    # Process static embedding datasets
    if static_processor:
        logger.info("Processing static embedding datasets")
        for dataset_name in datasets_to_process:
            try:
                logger.info(f"Processing static dataset: {dataset_name}")
                # Use transformer data if available for alignment
                transformer_data = transformer_results.get(dataset_name, None)
                
                static_processor.process_dataset(
                    dataset_name=dataset_name,
                    config=config,
                    output_dir=os.path.join(args.output_dir, 'static'),
                    transformer_data=transformer_data,
                    cache_dir=None if args.disable_cache else args.cache_dir,
                    force=args.force,
                    n_processes=args.n_processes
                )
            except Exception as e:
                logger.error(f"Error processing static dataset {dataset_name}: {e}")
    
    # Apply TPU optimization if requested
    if args.optimize_for_tpu:
        logger.info("Applying TPU optimization to processed datasets")
        
        for model_type in model_types:
            for dataset_name in datasets_to_process:
                dataset_dir = os.path.join(args.output_dir, model_type, dataset_name)
                if not os.path.exists(dataset_dir):
                    continue
                
                try:
                    logger.info(f"Optimizing {model_type} dataset {dataset_name} for TPU")
                    
                    # Load inputs and targets
                    inputs_path = os.path.join(dataset_dir, "inputs.pt")
                    targets_path = os.path.join(dataset_dir, "targets.pt")
                    
                    if not os.path.exists(inputs_path) or not os.path.exists(targets_path):
                        logger.warning(f"Input or target files not found in {dataset_dir}")
                        continue
                    
                    inputs = torch.load(inputs_path)
                    targets = torch.load(targets_path)
                    
                    # Create TPU-optimized formats
                    tpu_dir = os.path.join(dataset_dir, "tpu_optimized")
                    os.makedirs(tpu_dir, exist_ok=True)
                    
                    # Get optimal batch size for TPU
                    batch_size = config.get('batch_processing', {}).get('batch_size', 128)
                    # Round up to nearest multiple of 8 for TPU efficiency
                    batch_size = ((batch_size + 7) // 8) * 8
                    
                    # Optimize for TPU
                    optimize_for_tpu(inputs, targets, tpu_dir, model_type, batch_size)
                    logger.info(f"Successfully created TPU-optimized version in {tpu_dir}")
                    
                except Exception as e:
                    logger.error(f"Error optimizing {dataset_name} for TPU: {e}")
    
    # Show timing information if profiling enabled
    if args.profile:
        elapsed_time = time.time() - start_time
        logger.info(f"Total preprocessing time: {elapsed_time:.2f} seconds")

def main():
    """Main entry point for the data pipeline."""
    args = parse_args()
    
    try:
        # Load configuration
        config = load_config(args.config)
        if not config:
            logger.error("Failed to load configuration")
            return
        
        # Determine operation mode
        if args.download:
            download_datasets(config, args.force)
        elif args.view:
            view_datasets(args, config)
        else:  # Default is preprocess
            preprocess_datasets(args, config)
            
    except KeyboardInterrupt:
        logger.warning("Pipeline interrupted by user")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Pipeline execution failed: {e}", exc_info=True)
        sys.exit(1)

if __name__ == "__main__":
    main() 