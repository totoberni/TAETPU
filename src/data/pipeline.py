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

# Use relative imports instead of direct src imports
from ..configs import (
    load_config,
    DATA_PATHS
)

from ..utils import (
    ensure_directories_exist
)

from ..tpu import (
    optimize_for_tpu,
    set_xla_environment_variables,
    optimize_tensor_dimensions
)

# Import from data package using relative imports
from .types import TransformerInput, TransformerTarget, StaticInput, StaticTarget, TaskLabels
from .processors.transformer import TransformerProcessor
from .processors.static import StaticProcessor
from .io import load_dataset, download_all_datasets

# Setup logging
logger = logging.getLogger('data_pipeline')
logging.basicConfig(level=logging.INFO, 
                    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')

# Function that was moved from __init__.py
def ensure_data_directories():
    """Ensure all data directories exist."""
    data_dirs = [
        DATA_PATHS['DATASET_RAW_DIR'],
        DATA_PATHS['DATASET_CLEAN_STATIC_DIR'],
        DATA_PATHS['DATASET_CLEAN_TRANSFORMER_DIR']
    ]
    for path in data_dirs:
        os.makedirs(path, exist_ok=True)
        logger.debug(f"Ensured directory exists: {path}")

# Exposed wrapper function moved from __init__.py
def preprocess_dataset(dataset_name, model_type="all", optimize_tpu=True, force=False, cache_dir=None, n_processes=None, config=None):
    """
    Preprocess a dataset for specified model type with centralized logic.
    
    Args:
        dataset_name: Name of the dataset to process
        model_type: Model type ('transformer', 'static', or 'all')
        optimize_tpu: Whether to optimize for TPU
        force: Whether to force reprocessing
        cache_dir: Cache directory for intermediate results
        n_processes: Number of processes to use
        config: Custom config to use (or None to load default)
        
    Returns:
        Dictionary with processing results
    """
    if config is None:
        config = load_config()
    
    args = argparse.Namespace(
        preprocess=True,
        model=model_type,
        dataset=dataset_name,
        optimize_for_tpu=optimize_tpu,
        force=force,
        disable_cache=cache_dir is None,
        cache_dir=cache_dir or DATA_PATHS['CACHE_PREP_DIR'],
        output_dir=os.path.dirname(DATA_PATHS['DATASET_CLEAN_STATIC_DIR']),
        raw_dir=DATA_PATHS['DATASET_RAW_DIR'],
        n_processes=n_processes,
        config=DATA_PATHS['CONFIG_PATH'],
        profile=False
    )
    
    preprocess_datasets(args, config)
    
    # Return results
    result = {}
    model_types = ["transformer", "static"] if model_type == "all" else [model_type]
    for model in model_types:
        dataset_dir = os.path.join(os.path.dirname(DATA_PATHS['DATASET_CLEAN_STATIC_DIR']), 
                                  model, dataset_name)
        if os.path.exists(dataset_dir):
            result[model] = dataset_dir
    
    return result

# Exposed wrapper function moved from __init__.py
def download_datasets_wrapper(dataset_names=None, force=False, config=None):
    """
    Download datasets with centralized logic.
    
    Args:
        dataset_names: List of dataset names or None for all 
        force: Whether to force download even if dataset exists
        config: Custom config to use (or None to load default)
        
    Returns:
        True if successful, False if any failed
    """
    if config is None:
        config = load_config()
    
    # Filter datasets if names provided
    if dataset_names:
        original_datasets = config.get('datasets', {})
        filtered_datasets = {k: v for k, v in original_datasets.items() if k in dataset_names}
        config['datasets'] = filtered_datasets
    
    return download_all_datasets(config, DATA_PATHS['DATASET_RAW_DIR'], force)

# Exposed wrapper function moved from __init__.py
def view_dataset(dataset_name, model_type="all", dataset_type="clean", examples=3, detailed=False):
    """
    View a dataset with centralized logic.
    
    Args:
        dataset_name: Name of the dataset to view
        model_type: Model type ('transformer', 'static', or 'all')  
        dataset_type: Dataset type ('raw', 'clean', or 'auto')
        examples: Number of examples to show
        detailed: Whether to show detailed information
    """
    config = load_config()
    
    args = argparse.Namespace(
        view=True,
        model=model_type,
        dataset=dataset_name,
        dataset_type=dataset_type,
        examples=examples,
        detailed=detailed,
        output_dir=os.path.dirname(DATA_PATHS['DATASET_CLEAN_STATIC_DIR']),
        raw_dir=DATA_PATHS['DATASET_RAW_DIR'],
        config=DATA_PATHS['CONFIG_PATH']
    )
    
    view_datasets(args, config)

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
    parser.add_argument("--config", type=str, default=DATA_PATHS['CONFIG_PATH'], help="Path to config YAML file")
    parser.add_argument("--output-dir", type=str, default=os.path.dirname(DATA_PATHS['DATASET_CLEAN_STATIC_DIR']), help="Output directory")
    parser.add_argument("--cache-dir", type=str, default=DATA_PATHS['CACHE_PREP_DIR'], help="Cache directory")
    parser.add_argument("--raw-dir", type=str, default=DATA_PATHS['DATASET_RAW_DIR'], help="Raw datasets directory")
    
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
    logger.info("Starting dataset download stage")
    ensure_directories_exist([DATA_PATHS['DATASET_RAW_DIR']])
    
    # Use centralized function for downloading datasets
    return download_all_datasets(config, DATA_PATHS['DATASET_RAW_DIR'], force)

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
    
    # Set TPU environment variables if optimizing for TPU
    if args.optimize_for_tpu:
        set_xla_environment_variables()
    
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
                    
                    # Get optimal batch size for TPU (ensure multiple of 8)
                    batch_size = config.get('batch_processing', {}).get('batch_size', 128)
                    batch_size = optimize_tensor_dimensions(batch_size, 8)
                    
                    # Use the centralized optimize_for_tpu function
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