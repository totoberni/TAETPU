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
import time
from typing import Dict, List, Optional, Any, Union, Tuple
import torch
import numpy as np
from tqdm import tqdm

# Import custom modules
import processing_utils as utils
from process_transformer import preprocess_transformer_dataset
from process_static import preprocess_static_dataset
from data_import import process_gutenberg_dataset, process_emotion_dataset, save_dataset, check_existing_datasets, get_available_datasets, load_config
from data_types import TransformerInput, TransformerTarget, StaticInput, StaticTarget

# Constants - paths are mounted via Docker volumes
CONFIG_PATH = "/app/mount/src/configs/data_config.yaml"  # From host mount
DATASET_RAW_DIR = "/app/mount/src/datasets/raw"          # From tae_datasets volume
DATASET_CLEAN_DIR = "/app/mount/src/datasets/clean"      # From tae_datasets volume
CACHE_PREP_DIR = "/app/mount/src/cache/prep"             # From tae_cache volume
MODELS_PREP_DIR = "/app/mount/src/models/prep"           # From tae_models volume

# Setup logging
logger = utils.setup_logger('data_pipeline')

def validate_directories(config: Dict) -> bool:
    """
    Validate that required directories exist based on the configuration.
    Creates model type subdirectories in clean directory if they don't exist.
    """
    # Check if raw and clean base directories exist
    required_dirs = [DATASET_RAW_DIR, DATASET_CLEAN_DIR, CACHE_PREP_DIR, MODELS_PREP_DIR]
    for dir_path in required_dirs:
        if not os.path.exists(dir_path):
            logger.error(f"Required directory not found: {dir_path}")
            return False
    
    # Get available datasets from config
    if 'datasets' not in config:
        logger.error("No datasets defined in configuration")
        return False
    
    datasets = list(config['datasets'].keys())
    
    # Ensure dataset directories exist in raw directory
    for dataset in datasets:
        dataset_raw_path = os.path.join(DATASET_RAW_DIR, dataset)
        if not os.path.exists(dataset_raw_path):
            logger.warning(f"Raw dataset directory not found: {dataset_raw_path}")
            os.makedirs(dataset_raw_path, exist_ok=True)
            logger.info(f"Created raw dataset directory: {dataset_raw_path}")
    
    # Ensure model type directories exist in clean directory
    model_types = ['transformer', 'static']
    for model_type in model_types:
        model_dir = os.path.join(DATASET_CLEAN_DIR, model_type)
        if not os.path.exists(model_dir):
            logger.warning(f"Model type directory not found: {model_dir}")
            os.makedirs(model_dir, exist_ok=True)
            logger.info(f"Created model type directory: {model_dir}")
        
        # Create dataset subdirectories
        for dataset in datasets:
            dataset_clean_path = os.path.join(model_dir, dataset)
            if not os.path.exists(dataset_clean_path):
                os.makedirs(dataset_clean_path, exist_ok=True)
                logger.info(f"Created clean dataset directory: {dataset_clean_path}")
    
    return True

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
    
    # Dataset viewing
    parser.add_argument("--view", action="store_true", 
                        help="View datasets instead of processing them")
    parser.add_argument("--dataset-type", type=str, choices=["raw", "clean", "auto"],
                        default="auto", help="Type of datasets to view")
    parser.add_argument("--examples", type=int, default=3,
                        help="Number of examples to show for each dataset")
    parser.add_argument("--detailed", action="store_true",
                        help="Show detailed information about each example")
    
    # Resource configuration
    parser.add_argument("--config", type=str, default=CONFIG_PATH, 
                        help="Path to the data config YAML file")
    parser.add_argument("--output-dir", type=str, default=DATASET_CLEAN_DIR,
                        help="Output directory for processed datasets")
    parser.add_argument("--cache-dir", type=str, default=CACHE_PREP_DIR,
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

def view_datasets(
    datasets: List[str] = None,
    dataset_type: str = 'auto',
    model_types: List[str] = None,
    raw_dir: str = DATASET_RAW_DIR,
    clean_dir: str = DATASET_CLEAN_DIR,
    num_examples: int = 3,
    detailed: bool = False
) -> None:
    """
    View datasets in raw or processed format.
    
    Args:
        datasets: List of dataset names to view. If None, view all available datasets.
        dataset_type: Type of datasets to view ('raw', 'clean', or 'auto').
        model_types: For processed datasets, which model types to view ('transformer', 'static', or both).
        raw_dir: Directory containing raw datasets.
        clean_dir: Directory containing processed/clean datasets.
        num_examples: Number of examples to show for each dataset.
        detailed: Whether to show detailed information about each example.
    """
    from datasets import load_from_disk
    from transformers import AutoTokenizer
    
    # Determine dataset type if 'auto'
    if dataset_type == 'auto':
        raw_exists = os.path.exists(raw_dir) and len(os.listdir(raw_dir)) > 0
        clean_exists = os.path.exists(clean_dir) and len(os.listdir(clean_dir)) > 0
        
        if clean_exists:
            dataset_type = 'clean'
        elif raw_exists:
            dataset_type = 'raw'
        else:
            logger.error("No datasets found in either raw or clean directories")
            return
            
    logger.info(f"Viewing {dataset_type} datasets")
    
    # Set default model types
    if model_types is None and dataset_type == 'clean':
        model_types = ['transformer', 'static']
    
    # View raw datasets
    if dataset_type == 'raw':
        if not os.path.exists(raw_dir):
            logger.error(f"Raw dataset directory not found: {raw_dir}")
            return
            
        # Get available datasets
        available_datasets = [d for d in os.listdir(raw_dir) 
                             if os.path.isdir(os.path.join(raw_dir, d))]
        
        if not available_datasets:
            logger.info(f"No raw datasets found in {raw_dir}")
            return
            
        # Filter datasets if specified
        if datasets:
            available_datasets = [d for d in available_datasets if d in datasets]
            if not available_datasets:
                logger.warning(f"None of the specified datasets found in {raw_dir}")
                return
        
        logger.info(f"Available raw datasets: {available_datasets}")
        
        # View each dataset
        for dataset_name in available_datasets:
            logger.info(f"{'='*50}")
            logger.info(f"Dataset: {dataset_name}")
            logger.info(f"{'='*50}")
            
            dataset_path = os.path.join(raw_dir, dataset_name)
            try:
                dataset = load_from_disk(dataset_path)
                logger.info(f"Dataset splits: {list(dataset.keys())}")
                
                for split in dataset:
                    logger.info(f"Split: {split}")
                    logger.info(f"Number of examples: {len(dataset[split])}")
                    logger.info(f"Columns: {dataset[split].column_names}")
                    
                    # Show examples
                    if num_examples > 0:
                        logger.info(f"First {min(num_examples, len(dataset[split]))} examples:")
                        for i, example in enumerate(dataset[split].select(range(min(num_examples, len(dataset[split]))))):
                            logger.info(f"Example {i+1}:")
                            for column in dataset[split].column_names:
                                # Truncate long text values
                                value = example[column]
                                if isinstance(value, str) and len(value) > 100:
                                    value = value[:100] + "..."
                                logger.info(f"  {column}: {value}")
            
            except Exception as e:
                logger.error(f"Error viewing dataset {dataset_name}: {e}")
    
    # View clean/processed datasets
    elif dataset_type == 'clean':
        if not os.path.exists(clean_dir):
            logger.error(f"Clean dataset directory not found: {clean_dir}")
            return
            
        # Find all available datasets by model type
        all_datasets = set()
        model_to_datasets = {}
        
        # Check each model type directory
        for model_type in ['transformer', 'static']:
            model_dir = os.path.join(clean_dir, model_type)
            if not os.path.exists(model_dir):
                logger.warning(f"Model type directory not found: {model_dir}")
                continue
                
            # Get datasets for this model type
            model_datasets = [d for d in os.listdir(model_dir) 
                             if os.path.isdir(os.path.join(model_dir, d))]
            
            model_to_datasets[model_type] = model_datasets
            all_datasets.update(model_datasets)
        
        if not all_datasets:
            logger.info(f"No clean datasets found in {clean_dir}")
            return
            
        # Filter datasets if specified
        if datasets:
            all_datasets = [d for d in all_datasets if d in datasets]
            if not all_datasets:
                logger.warning(f"None of the specified datasets found in {clean_dir}")
                return
        
        logger.info(f"Available clean datasets: {list(all_datasets)}")
        for model_type, model_datasets in model_to_datasets.items():
            filtered_datasets = [d for d in model_datasets if d in all_datasets]
            if filtered_datasets:
                logger.info(f"{model_type.capitalize()} datasets: {filtered_datasets}")
        
        # View each dataset
        for dataset_name in all_datasets:
            # View transformer dataset
            if 'transformer' in model_types and dataset_name in model_to_datasets.get('transformer', []):
                logger.info(f"{'='*50}")
                logger.info(f"Transformer Dataset: {dataset_name}")
                logger.info(f"{'='*50}")
                
                dataset_path = os.path.join(clean_dir, 'transformer', dataset_name)
                inputs_path = os.path.join(dataset_path, "inputs.pt")
                targets_path = os.path.join(dataset_path, "targets.pt")
                
                if not os.path.exists(inputs_path) or not os.path.exists(targets_path):
                    logger.warning(f"Input or target files not found in {dataset_path}")
                    continue
                
                try:
                    inputs = torch.load(inputs_path)
                    targets = torch.load(targets_path)
                    
                    logger.info(f"Number of examples: {len(inputs)}")
                    
                    # Load tokenizer
                    tokenizer_path = os.path.join(dataset_path, "tokenizer")
                    if os.path.exists(tokenizer_path):
                        tokenizer = AutoTokenizer.from_pretrained(tokenizer_path)
                        logger.info(f"Tokenizer vocabulary size: {tokenizer.vocab_size}")
                    else:
                        tokenizer = None
                        logger.warning("Tokenizer not found")
                    
                    # Show examples
                    if num_examples > 0:
                        logger.info(f"First {min(num_examples, len(inputs))} examples:")
                        for i in range(min(num_examples, len(inputs))):
                            logger.info(f"Example {i+1}:")
                            
                            # Basic info
                            logger.info(f"  Input shape: {inputs[i].input_ids.shape}")
                            
                            # Decode tokens if tokenizer is available and detailed view is requested
                            if detailed and tokenizer:
                                input_text = tokenizer.decode(
                                    inputs[i].input_ids[inputs[i].attention_mask.astype(bool)]
                                )
                                if len(input_text) > 100:
                                    input_text = input_text[:100] + "..."
                                logger.info(f"  Text: {input_text}")
                            
                            # Task labels
                            if hasattr(targets[i], 'task_labels') and targets[i].task_labels:
                                logger.info("  Task Labels:")
                                for task, labels in targets[i].task_labels.items():
                                    logger.info(f"    {task}: {labels.labels.shape}")
                            
                            # Metadata for detailed view
                            if detailed and hasattr(inputs[i], 'metadata') and inputs[i].metadata:
                                logger.info("  Metadata:")
                                for key, value in inputs[i].metadata.items():
                                    if key in ['word_ids', 'alignment_map']:
                                        logger.info(f"    {key}: [Array of length {len(value) if value is not None else 0}]")
                                    elif isinstance(value, str) and len(value) > 100:
                                        logger.info(f"    {key}: {value[:100]}...")
                                    else:
                                        logger.info(f"    {key}: {value}")
                
                except Exception as e:
                    logger.error(f"Error viewing transformer dataset {dataset_name}: {e}")
            
            # View static dataset
            if 'static' in model_types and dataset_name in model_to_datasets.get('static', []):
                logger.info(f"{'='*50}")
                logger.info(f"Static Dataset: {dataset_name}")
                logger.info(f"{'='*50}")
                
                dataset_path = os.path.join(clean_dir, 'static', dataset_name)
                inputs_path = os.path.join(dataset_path, "inputs.pt")
                targets_path = os.path.join(dataset_path, "targets.pt")
                
                if not os.path.exists(inputs_path) or not os.path.exists(targets_path):
                    logger.warning(f"Input or target files not found in {dataset_path}")
                    continue
                
                try:
                    inputs = torch.load(inputs_path)
                    targets = torch.load(targets_path)
                    
                    logger.info(f"Number of examples: {len(inputs)}")
                    
                    # Show examples
                    if num_examples > 0:
                        logger.info(f"First {min(num_examples, len(inputs))} examples:")
                        for i in range(min(num_examples, len(inputs))):
                            logger.info(f"Example {i+1}:")
                            
                            # Basic info
                            logger.info(f"  Center Words shape: {inputs[i].center_words.shape}")
                            logger.info(f"  Context Words shape: {inputs[i].context_words.shape}")
                            
                            # Task labels
                            if hasattr(targets[i], 'task_labels') and targets[i].task_labels:
                                logger.info("  Task Labels:")
                                for task, labels in targets[i].task_labels.items():
                                    logger.info(f"    {task}: {labels.labels.shape}")
                            
                            # Metadata for detailed view
                            if detailed and hasattr(inputs[i], 'metadata') and inputs[i].metadata:
                                logger.info("  Metadata:")
                                for key, value in inputs[i].metadata.items():
                                    if key == 'alignment_map':
                                        logger.info(f"    {key}: [Dictionary with {len(value) if value is not None else 0} mappings]")
                                    elif isinstance(value, str) and len(value) > 100:
                                        logger.info(f"    {key}: {value[:100]}...")
                                    else:
                                        logger.info(f"    {key}: {value}")
                
                except Exception as e:
                    logger.error(f"Error viewing static dataset {dataset_name}: {e}")
            
            # Check TPU-optimized datasets if detailed view is requested
            if detailed:
                # Transformer TPU
                if 'transformer' in model_types and dataset_name in model_to_datasets.get('transformer', []):
                    tpu_dir = os.path.join(clean_dir, 'transformer', dataset_name, "tpu_optimized")
                    if os.path.exists(tpu_dir):
                        logger.info(f"{'='*50}")
                        logger.info(f"TPU-Optimized Transformer Dataset: {dataset_name}")
                        logger.info(f"{'='*50}")
                        
                        files = [f for f in os.listdir(tpu_dir) if f.endswith('.npy')]
                        logger.info(f"Available TPU-optimized arrays: {files}")
                        
                        # Show details for key arrays
                        for field in ['input_ids.npy', 'attention_mask.npy', 'labels.npy']:
                            if field in files:
                                array_path = os.path.join(tpu_dir, field)
                                try:
                                    array = np.load(array_path)
                                    logger.info(f"{field}:")
                                    logger.info(f"  Shape: {array.shape}")
                                    logger.info(f"  Dtype: {array.dtype}")
                                except Exception as e:
                                    logger.error(f"Error loading {field}: {e}")
                
                # Static TPU
                if 'static' in model_types and dataset_name in model_to_datasets.get('static', []):
                    tpu_dir = os.path.join(clean_dir, 'static', dataset_name, "tpu_optimized")
                    if os.path.exists(tpu_dir):
                        logger.info(f"{'='*50}")
                        logger.info(f"TPU-Optimized Static Dataset: {dataset_name}")
                        logger.info(f"{'='*50}")
                        
                        files = [f for f in os.listdir(tpu_dir) if f.endswith('.npy')]
                        logger.info(f"Available TPU-optimized arrays: {files}")
                        
                        # Show details for key arrays
                        for field in ['center_words.npy', 'context_words.npy', 'target_values.npy']:
                            if field in files:
                                array_path = os.path.join(tpu_dir, field)
                                try:
                                    array = np.load(array_path)
                                    logger.info(f"{field}:")
                                    logger.info(f"  Shape: {array.shape}")
                                    logger.info(f"  Dtype: {array.dtype}")
                                except Exception as e:
                                    logger.error(f"Error loading {field}: {e}")

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
    output_base_dir: str = DATASET_CLEAN_DIR,
    cache_dir: str = CACHE_PREP_DIR,
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
        output_dir = os.path.join(output_base_dir, 'transformer')
        
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
        output_dir = os.path.join(output_base_dir, 'static')
        
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
    output_base_dir: str = DATASET_CLEAN_DIR,
    cache_dir: str = CACHE_PREP_DIR,
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
    output_base_dir: str = DATASET_CLEAN_DIR
) -> None:
    """Optimize processed datasets for TPU compatibility."""
    logger.info("Optimizing datasets for TPU compatibility")
    
    batch_size = config.get('batch_processing', {}).get('batch_size', 128)
    
    for model_type in model_types:
        output_dir = os.path.join(output_base_dir, model_type)
        
        for dataset_name in datasets:
            dataset_dir = os.path.join(output_dir, dataset_name)
            
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
                    example['labels'] = target_obj.labels if hasattr(target_obj, 'labels') else None
                    example['label_mask'] = target_obj.attention_mask if hasattr(target_obj, 'attention_mask') else None
                    
                    # Add task-specific labels
                    if hasattr(target_obj, 'task_labels') and target_obj.task_labels:
                        for task_name, task_labels in target_obj.task_labels.items():
                            example[f"{task_name}_labels"] = task_labels.labels
                            if task_labels.mask is not None:
                                example[f"{task_name}_mask"] = task_labels.mask
                    
                    examples.append(example)
                
                # Create TPU-optimized dataset
                fields = set()
                for example in examples:
                    fields.update(example.keys())
                
                # Filter out None fields
                fields = [field for field in fields if field is not None and any(example.get(field) is not None for example in examples)]
                
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
    
    # Validate directories
    if not validate_directories(config):
        logger.error("Directory validation failed. Exiting.")
        return
    
    # Determine which datasets to process
    if args.dataset == "all":
        datasets_to_process = list(config['datasets'].keys())
    else:
        datasets_to_process = [args.dataset]
    
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
            output_base_dir=args.output_dir,
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
            output_base_dir=args.output_dir,
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
            output_base_dir=args.output_dir
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
        # Load configuration
        config = load_config(args.config)
        
        # Validate directories
        if not validate_directories(config):
            logger.error("Directory validation failed. Exiting.")
            return
        
        # Determine which datasets to process/view
        if args.dataset == "all":
            datasets_to_process = list(config['datasets'].keys())
        else:
            datasets_to_process = [args.dataset]
        
        # Determine which model types to process/view
        if args.model == "all":
            model_types = ["transformer", "static"]
        else:
            model_types = [args.model]
        
        # View datasets if requested
        if args.view:
            view_datasets(
                datasets=datasets_to_process,
                dataset_type=args.dataset_type,
                model_types=model_types,
                raw_dir=args.raw_dir,
                clean_dir=args.output_dir,
                num_examples=args.examples,
                detailed=args.detailed
            )
            return
        
        # Run pipeline
        run_pipeline(args)
        
    except KeyboardInterrupt:
        logger.warning("Pipeline interrupted by user")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Pipeline execution failed: {e}", exc_info=True)
        sys.exit(1)

if __name__ == "__main__":
    main()