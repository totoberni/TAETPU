"""
Data Pipeline Entry Point for Transformer Ablation Experiments.

This module serves as the main entry point for preprocessing data for transformer
ablation experiments. It orchestrates the processing workflow, handles command-line
arguments, and coordinates the different preprocessing stages.
"""

import os
import sys
import argparse
import logging
from typing import Dict, List, Optional, Any, Union
import torch
import numpy as np
from tqdm import tqdm

# Import custom modules
import processing_utils as utils
from preprocess_transformer import preprocess_transformer_dataset
from preprocess_static import preprocess_static_dataset
from data_import import process_gutenberg_dataset, process_emotion_dataset, save_dataset, check_existing_datasets
from data_types import TransformerInput, TransformerTarget, StaticInput, StaticTarget

# Constants
CONFIG_PATH = "/app/mount/src/configs/data_config.yaml"
DATASET_RAW_DIR = "/app/mount/src/datasets/raw"
DATASET_PROCESSED_DIR = "/app/mount/src/datasets/processed"
CACHE_DIR = "/app/mount/src/cache"
MODELS_DIR = "/app/mount/src/models"

# Setup logging
logger = utils.setup_logger('data_pipeline')

def parse_args() -> argparse.Namespace:
    """Parse command-line arguments for the data pipeline."""
    parser = argparse.ArgumentParser(description="Data Pipeline for Transformer Ablation Experiments")
    
    # Main operation mode
    parser.add_argument("--model", type=str, choices=["transformer", "static", "all"],
                        default="all", help="Model type to preprocess data for")
    parser.add_argument("--dataset", type=str, choices=["gutenberg", "emotion", "all"],
                        default="all", help="Dataset to preprocess")
    
    # Pipeline control
    parser.add_argument("--start-stage", type=str, choices=["download", "tokenization", "label_generation"],
                        default="download", help="Stage to start processing from")
    parser.add_argument("--end-stage", type=str, choices=["download", "tokenization", "label_generation", "all"],
                        default="all", help="Stage to end processing at")
    
    # Resource configuration
    parser.add_argument("--config", type=str, default=CONFIG_PATH, 
                        help="Path to the data config YAML file")
    parser.add_argument("--output-dir", type=str, default=DATASET_PROCESSED_DIR,
                        help="Output directory for processed datasets")
    parser.add_argument("--cache-dir", type=str, default=CACHE_DIR,
                        help="Cache directory for preprocessed data")
    parser.add_argument("--raw-dir", type=str, default=DATASET_RAW_DIR,
                        help="Directory with raw datasets")
    
    # Processing options
    parser.add_argument("--force", action="store_true",
                        help="Force overwrite existing processed data")
    parser.add_argument("--disable-cache", action="store_true",
                        help="Disable caching of preprocessed data")
    parser.add_argument("--n-processes", type=int, default=None,
                        help="Number of processes for parallel processing")
    parser.add_argument("--optimize-for-tpu", action="store_true",
                        help="Optimize preprocessing for TPU compatibility")
    parser.add_argument("--profile", action="store_true",
                        help="Enable performance profiling")
    
    return parser.parse_args()

def download_datasets(
    datasets: List[str],
    config: Dict,
    raw_dir: str = DATASET_RAW_DIR,
    force: bool = False
) -> Dict[str, Any]:
    """Download and prepare raw datasets."""
    logger.info("Starting dataset download stage")
    
    # Check if raw directory exists
    os.makedirs(raw_dir, exist_ok=True)
    
    # Check for existing datasets
    if not check_existing_datasets(force):
        logger.warning("Dataset download cancelled. Use --force to overwrite existing datasets.")
        return {}
    
    results = {}
    
    # Process specified datasets
    for dataset_name in datasets:
        logger.info(f"Processing dataset: {dataset_name}")
        
        if dataset_name == "gutenberg":
            try:
                data = process_gutenberg_dataset()
                save_dataset(data, "gutenberg")
                results["gutenberg"] = True
            except Exception as e:
                logger.error(f"Failed to process gutenberg dataset: {e}")
                results["gutenberg"] = False
        
        elif dataset_name == "emotion":
            try:
                data = process_emotion_dataset()
                save_dataset(data, "emotion")
                results["emotion"] = True
            except Exception as e:
                logger.error(f"Failed to process emotion dataset: {e}")
                results["emotion"] = False
    
    return results

def tokenize_datasets(
    datasets: List[str],
    model_types: List[str],
    config: Dict,
    output_dir: str = DATASET_PROCESSED_DIR,
    cache_dir: str = CACHE_DIR,
    force: bool = False,
    use_cache: bool = True,
    n_processes: int = None,
    optimize_for_tpu: bool = False
) -> Dict[str, Dict[str, Any]]:
    """Tokenize datasets for specified model types."""
    logger.info("Starting tokenization stage")
    
    results = {}
    
    # Process transformer tokenization if requested
    if "transformer" in model_types:
        transformer_results = {}
        
        for dataset_name in datasets:
            logger.info(f"Tokenizing {dataset_name} for transformer model")
            try:
                result = preprocess_transformer_dataset(
                    dataset_name=dataset_name,
                    data_config=config,
                    output_dir=output_dir,
                    cache_dir=cache_dir,
                    force=force,
                    use_cache=use_cache,
                    n_processes=n_processes
                )
                transformer_results[dataset_name] = result
            except Exception as e:
                logger.error(f"Failed to tokenize {dataset_name} for transformer: {e}")
                transformer_results[dataset_name] = None
        
        results["transformer"] = transformer_results
    
    # Process static tokenization if requested
    if "static" in model_types:
        static_results = {}
        
        for dataset_name in datasets:
            logger.info(f"Tokenizing {dataset_name} for static embedding model")
            try:
                # Use transformer data if available
                transformer_data = None
                if "transformer" in results and dataset_name in results["transformer"]:
                    transformer_data = results["transformer"][dataset_name]
                
                preprocess_static_dataset(
                    dataset_name=dataset_name,
                    data_config=config,
                    output_dir=output_dir,
                    transformer_data=transformer_data,
                    cache_dir=cache_dir,
                    force=force,
                    use_cache=use_cache,
                    n_processes=n_processes
                )
                static_results[dataset_name] = True
            except Exception as e:
                logger.error(f"Failed to tokenize {dataset_name} for static embedding: {e}")
                static_results[dataset_name] = False
        
        results["static"] = static_results
    
    return results

def generate_task_labels(
    datasets: List[str],
    model_types: List[str],
    config: Dict,
    output_dir: str = DATASET_PROCESSED_DIR,
    cache_dir: str = CACHE_DIR,
    force: bool = False,
    use_cache: bool = True,
    n_processes: int = None
) -> Dict[str, Dict[str, Any]]:
    """Generate task-specific labels for preprocessed datasets."""
    logger.info("Starting task label generation stage")
    
    # This function will be implemented separately in task_generators.py
    # For now, we'll just return a placeholder
    
    logger.warning("Task label generation not yet implemented")
    return {model: {dataset: False for dataset in datasets} for model in model_types}

def optimize_for_tpu(
    datasets: List[str],
    model_types: List[str],
    config: Dict,
    output_dir: str = DATASET_PROCESSED_DIR
) -> None:
    """Optimize processed datasets for TPU compatibility."""
    logger.info("Optimizing datasets for TPU compatibility")
    
    batch_size = config.get('batch_processing', {}).get('batch_size', 128)
    
    for model_type in model_types:
        for dataset_name in datasets:
            dataset_dir = os.path.join(output_dir, f"{dataset_name}_{model_type}")
            
            if not os.path.exists(dataset_dir):
                logger.warning(f"Dataset directory not found: {dataset_dir}")
                continue
            
            # Load inputs and targets
            try:
                inputs_path = os.path.join(dataset_dir, "inputs.pt")
                targets_path = os.path.join(dataset_dir, "targets.pt")
                
                if not os.path.exists(inputs_path) or not os.path.exists(targets_path):
                    logger.warning(f"Input or target files not found in {dataset_dir}")
                    continue
                
                inputs = torch.load(inputs_path)
                targets = torch.load(targets_path)
                
                # Convert to list of dictionaries for TPU optimization
                examples = []
                for input_obj, target_obj in zip(inputs, targets):
                    example = {}
                    
                    # Extract fields from input
                    for field in ['input_ids', 'attention_mask', 'token_type_ids', 'special_tokens_mask']:
                        if hasattr(input_obj, field):
                            example[field] = getattr(input_obj, field)
                    
                    # Extract fields from target
                    example['labels'] = target_obj.labels
                    example['label_mask'] = target_obj.attention_mask
                    
                    # Add task-specific labels
                    for task_name, task_labels in target_obj.task_labels.items():
                        example[f"{task_name}_labels"] = task_labels.labels
                        if task_labels.mask is not None:
                            example[f"{task_name}_mask"] = task_labels.mask
                    
                    examples.append(example)
                
                # Create TPU-optimized dataset
                fields = set()
                for example in examples:
                    fields.update(example.keys())
                
                logger.info(f"Optimizing {dataset_name} for {model_type} model with {len(examples)} examples")
                tpu_dataset = utils.create_tpu_optimized_dataset(examples, list(fields), batch_size)
                
                # Save optimized dataset
                tpu_output_dir = os.path.join(dataset_dir, "tpu_optimized")
                os.makedirs(tpu_output_dir, exist_ok=True)
                
                for field, array in tpu_dataset.items():
                    np.save(os.path.join(tpu_output_dir, f"{field}.npy"), array)
                
                logger.info(f"Saved TPU-optimized dataset to {tpu_output_dir}")
                
            except Exception as e:
                logger.error(f"Failed to optimize {dataset_name} for TPU: {e}")

def run_pipeline(args: argparse.Namespace) -> None:
    """Run the data preprocessing pipeline with the specified arguments."""
    # Load configuration
    config = utils.load_config(args.config)
    
    # Determine which datasets to process
    datasets_to_process = list(config['datasets'].keys()) if args.dataset == "all" else [args.dataset]
    
    # Determine which model types to process
    if args.model == "all":
        model_types = ["transformer", "static"]
    else:
        model_types = [args.model]
    
    # Set up cache directory
    cache_dir = args.cache_dir if not args.disable_cache else None
    
    # Create output directories
    os.makedirs(args.output_dir, exist_ok=True)
    if cache_dir:
        os.makedirs(cache_dir, exist_ok=True)
    
    # Profile if requested
    if args.profile:
        import time
        start_time = time.time()
    
    # Stage 1: Download datasets
    if args.start_stage in ["download"]:
        download_results = download_datasets(
            datasets=datasets_to_process,
            config=config,
            raw_dir=args.raw_dir,
            force=args.force
        )
        
        # Check results before continuing
        if not all(download_results.values()):
            failed = [name for name, result in download_results.items() if not result]
            logger.warning(f"Failed to download some datasets: {', '.join(failed)}")
            
            if args.start_stage == "download":
                logger.error("Cannot continue to next stage due to download failures")
                return
    
    # Stage 2: Tokenize datasets
    if args.start_stage in ["download", "tokenization"] and args.end_stage in ["tokenization", "label_generation", "all"]:
        tokenize_results = tokenize_datasets(
            datasets=datasets_to_process,
            model_types=model_types,
            config=config,
            output_dir=args.output_dir,
            cache_dir=cache_dir,
            force=args.force,
            use_cache=not args.disable_cache,
            n_processes=args.n_processes,
            optimize_for_tpu=args.optimize_for_tpu
        )
        
        # Check results before continuing
        all_success = True
        for model_type, model_results in tokenize_results.items():
            for dataset_name, result in model_results.items():
                if not result:
                    all_success = False
                    logger.warning(f"Failed to tokenize {dataset_name} for {model_type}")
        
        if not all_success and args.start_stage == "tokenization":
            logger.error("Cannot continue to next stage due to tokenization failures")
            return
    
    # Stage 3: Generate task-specific labels
    if args.start_stage in ["download", "tokenization", "label_generation"] and args.end_stage in ["label_generation", "all"]:
        label_results = generate_task_labels(
            datasets=datasets_to_process,
            model_types=model_types,
            config=config,
            output_dir=args.output_dir,
            cache_dir=cache_dir,
            force=args.force,
            use_cache=not args.disable_cache,
            n_processes=args.n_processes
        )
    
    # TPU optimization if requested
    if args.optimize_for_tpu:
        optimize_for_tpu(
            datasets=datasets_to_process,
            model_types=model_types,
            config=config,
            output_dir=args.output_dir
        )
    
    # Show timing information if profiling enabled
    if args.profile:
        elapsed_time = time.time() - start_time
        logger.info(f"Pipeline execution time: {elapsed_time:.2f} seconds")
    
    logger.info("Data pipeline execution complete")

def main():
    """Main entry point for the data pipeline."""
    args = parse_args()
    
    try:
        run_pipeline(args)
    except KeyboardInterrupt:
        logger.warning("Pipeline interrupted by user")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Pipeline execution failed: {e}", exc_info=True)
        sys.exit(1)

if __name__ == "__main__":
    main()