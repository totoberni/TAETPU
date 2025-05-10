"""
Data input/output utilities.

This module provides functions for loading datasets, downloading files,
and other data I/O operations with TPU optimization.
"""

import os
import logging
import json
from typing import Dict, Any, List, Optional

# Configure logger
logger = logging.getLogger('utils.data_io')

def load_dataset(dataset_name: str, raw_dir: str) -> Any:
    """
    Load dataset from disk, verifying it exists first.
    
    Args:
        dataset_name: Name of the dataset to load
        raw_dir: Directory with raw datasets
    
    Returns:
        Loaded dataset
    """
    try:
        from datasets import load_from_disk
        
        dataset_path = os.path.join(raw_dir, dataset_name)
        
        # Check if dataset exists
        if not os.path.exists(dataset_path):
            raise FileNotFoundError(f"Dataset '{dataset_name}' not found at {dataset_path}")
        
        logger.info(f"Loading dataset from {dataset_path}")
        return load_from_disk(dataset_path)
    
    except ImportError:
        logger.error("datasets library is not installed. Install with 'pip install datasets'")
        raise

def download_dataset(dataset_name: str, output_dir: str, config: Dict) -> bool:
    """
    Download dataset from Hugging Face and save to disk.
    
    Args:
        dataset_name: Name of the dataset to download
        output_dir: Directory to save the downloaded dataset
        config: Configuration with dataset options
    
    Returns:
        True if successful, False otherwise
    """
    try:
        from datasets import load_dataset
        
        # Get dataset info from config
        dataset_config = config['datasets'].get(dataset_name, {})
        hf_name = dataset_config.get('hf_name', dataset_name)
        
        # Handle specific datasets with custom logic
        if dataset_name == "gutenberg":
            dataset = load_dataset("nbeerbower/gutenberg2-dpo")
            # Keep only the 'chosen' column
            dataset = dataset.remove_columns([c for c in dataset["train"].column_names if c != "chosen"])
        elif dataset_name == "emotion":
            dataset = load_dataset("dair-ai/emotion")
            # Rename 'label' to 'emo_label' for clarity
            dataset = dataset.rename_column("label", "emo_label")
        else:
            # Generic dataset loading
            dataset = load_dataset(hf_name)
        
        # Create output directory
        os.makedirs(output_dir, exist_ok=True)
        
        # Save dataset to disk
        dataset_path = os.path.join(output_dir, dataset_name)
        os.makedirs(dataset_path, exist_ok=True)
        dataset.save_to_disk(dataset_path)
        
        logger.info(f"Successfully downloaded and saved dataset: {dataset_name}")
        return True
    
    except Exception as e:
        logger.error(f"Error downloading dataset {dataset_name}: {e}")
        return False

def download_all_datasets(config: Dict, raw_dir: str, force: bool = False) -> bool:
    """
    Download and prepare all raw datasets from Hugging Face.
    
    Args:
        config: Configuration dictionary
        raw_dir: Directory to save raw datasets
        force: Whether to force download even if dataset exists
    
    Returns:
        True if all successful, False if any failed
    """
    # Extract dataset configurations
    if 'datasets' not in config:
        logger.error("No datasets defined in configuration")
        return False
    
    datasets_config = config['datasets']
    success = True
    
    for dataset_name in datasets_config:
        dataset_path = os.path.join(raw_dir, dataset_name)
        
        # Skip if dataset exists and force is False
        if os.path.exists(dataset_path) and not force:
            logger.info(f"Dataset {dataset_name} already exists. Use --force to overwrite.")
            continue
        
        logger.info(f"Downloading dataset: {dataset_name}")
        success &= download_dataset(dataset_name, raw_dir, config)
    
    return success

def save_processed_dataset(
    dataset_data: Dict,
    output_dir: str,
    dataset_name: str,
    model_type: str
) -> None:
    """
    Save processed dataset to disk.
    
    Args:
        dataset_data: Dictionary with processed dataset data
        output_dir: Base directory for clean datasets
        dataset_name: Name of the dataset
        model_type: 'transformer' or 'static'
    """
    import torch
    
    # Create dataset-specific output directory
    dataset_dir = os.path.join(output_dir, model_type, dataset_name)
    os.makedirs(dataset_dir, exist_ok=True)
    
    # Save inputs and targets
    if 'inputs' in dataset_data:
        torch.save(dataset_data['inputs'], os.path.join(dataset_dir, "inputs.pt"))
    
    if 'targets' in dataset_data:
        torch.save(dataset_data['targets'], os.path.join(dataset_dir, "targets.pt"))
    
    # Save vocabulary for static models
    if model_type == 'static' and 'vocabulary' in dataset_data:
        torch.save(dataset_data['vocabulary'], os.path.join(dataset_dir, "vocabulary.pt"))
    
    # Save tokenizer for transformer models
    if model_type == 'transformer' and 'tokenizer' in dataset_data:
        dataset_data['tokenizer'].save_pretrained(os.path.join(dataset_dir, "tokenizer"))
    
    # Save metadata
    if 'metadata' in dataset_data:
        with open(os.path.join(dataset_dir, "metadata.json"), 'w') as f:
            metadata = {k: v for k, v in dataset_data['metadata'].items() 
                      if isinstance(v, (str, int, float, bool, list, dict))}
            json.dump(metadata, f, indent=2)
    
    logger.info(f"Saved {model_type} processed data for {dataset_name} to {dataset_dir}")

def save_dataset(
    dataset: Any,
    dataset_name: str,
    output_dir: str,
    create_subdirs: bool = True
) -> str:
    """
    Save dataset to disk in the specified format.
    
    Args:
        dataset: Dataset to save
        dataset_name: Name of the dataset
        output_dir: Directory to save the dataset
        create_subdirs: Whether to create a subdirectory for the dataset
        
    Returns:
        Path where the dataset was saved
    """
    try:
        from datasets import Dataset, DatasetDict
    except ImportError:
        logger.error("Failed to import datasets. Install with 'pip install datasets'")
        raise
    
    # Create output directory
    if create_subdirs:
        save_path = os.path.join(output_dir, dataset_name)
    else:
        save_path = output_dir
        
    os.makedirs(save_path, exist_ok=True)
    
    # Check dataset type and save accordingly
    if isinstance(dataset, (Dataset, DatasetDict)):
        # HuggingFace dataset
        dataset.save_to_disk(save_path)
        logger.info(f"Saved HuggingFace dataset to {save_path}")
    else:
        # Fallback for other types
        import torch
        torch.save(dataset, os.path.join(save_path, "dataset.pt"))
        logger.info(f"Saved generic dataset to {save_path}")
    
    return save_path

def load_processed_data(
    dataset_name: str,
    model_type: str,
    base_dir: str = None
) -> Dict[str, Any]:
    """
    Load processed input and target data for a dataset.
    
    Args:
        dataset_name: Name of the dataset
        model_type: 'transformer' or 'static'
        base_dir: Base directory for clean datasets. If None, uses CONTAINER_MOUNT_DIR from env.
        
    Returns:
        Dictionary with loaded inputs and targets
    """
    import torch
    
    # Get base directory from environment variable if not provided
    if base_dir is None:
        container_mount_dir = os.environ.get('CONTAINER_MOUNT_DIR', '/app/mount')
        base_dir = os.path.join(container_mount_dir, 'src/datasets/clean')
    
    dataset_dir = os.path.join(base_dir, model_type, dataset_name)
    
    if not os.path.exists(dataset_dir):
        raise FileNotFoundError(f"Processed dataset not found at {dataset_dir}")
    
    inputs_path = os.path.join(dataset_dir, "inputs.pt")
    targets_path = os.path.join(dataset_dir, "targets.pt")
    
    if not os.path.exists(inputs_path) or not os.path.exists(targets_path):
        raise FileNotFoundError(f"Inputs or targets file not found in {dataset_dir}")
    
    logger.info(f"Loading processed data from {dataset_dir}")
    
    result = {
        'inputs': torch.load(inputs_path),
        'targets': torch.load(targets_path)
    }
    
    # Load tokenizer if it exists
    tokenizer_path = os.path.join(dataset_dir, "tokenizer")
    if os.path.exists(tokenizer_path):
        from transformers import AutoTokenizer
        result['tokenizer'] = AutoTokenizer.from_pretrained(tokenizer_path)
    
    # Check for TPU-optimized data
    tpu_dir = os.path.join(dataset_dir, "tpu_optimized")
    if os.path.exists(tpu_dir):
        result['has_tpu_optimized'] = True
        
        # Load metadata if available
        metadata_path = os.path.join(tpu_dir, "metadata.json")
        if os.path.exists(metadata_path):
            with open(metadata_path, 'r') as f:
                result['tpu_metadata'] = json.load(f)
        
        # List available TPU arrays
        result['tpu_arrays'] = [
            f for f in os.listdir(tpu_dir) if f.endswith('.npy')
        ]
    
    return result

def export_to_tfrecord(
    data: Dict[str, Any],
    output_path: str,
    batch_size: int = 128
) -> str:
    """
    Export data to TFRecord format for TensorFlow/TPU compatibility.
    
    Args:
        data: Data to export
        output_path: Path to save TFRecord file
        batch_size: Batch size for examples
        
    Returns:
        Path to the saved TFRecord file
    """
    try:
        import tensorflow as tf
        import numpy as np
    except ImportError:
        logger.error("Failed to import tensorflow. Install with 'pip install tensorflow'")
        raise
    
    # Create output directory
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    
    # Define feature conversion function
    def _bytes_feature(value):
        """Returns a bytes_list feature."""
        if isinstance(value, type(tf.constant(0))):
            value = value.numpy()
        return tf.train.Feature(bytes_list=tf.train.BytesList(value=[value]))
    
    def _int64_feature(value):
        """Returns an int64_list feature."""
        return tf.train.Feature(int64_list=tf.train.Int64List(value=[value]))
    
    # Create TFRecord writer
    with tf.io.TFRecordWriter(output_path) as writer:
        # Determine number of examples
        num_examples = 0
        for k, v in data.items():
            if isinstance(v, (list, np.ndarray)) and len(v) > 0:
                num_examples = len(v)
                break
        
        if num_examples == 0:
            logger.warning("No examples found in data")
            return output_path
        
        # Process examples in batches
        for start_idx in range(0, num_examples, batch_size):
            end_idx = min(start_idx + batch_size, num_examples)
            
            # Process batch
            for i in range(start_idx, end_idx):
                feature = {}
                
                # Add all features from data
                for key, value in data.items():
                    if isinstance(value, (list, np.ndarray)) and len(value) > i:
                        # Convert array to bytes
                        array = value[i]
                        if isinstance(array, np.ndarray):
                            feature[key] = _bytes_feature(array.tobytes())
                        else:
                            # Skip non-array values
                            continue
                    elif isinstance(value, dict) and 'shape' in value and 'dtype' in value:
                        # Handle metadata
                        continue
                
                # Add metadata if needed
                for key, value in data.items():
                    if isinstance(value, (list, np.ndarray)) and len(value) > i:
                        array = value[i]
                        if isinstance(array, np.ndarray):
                            # Add shape and dtype information
                            feature[f"{key}_shape"] = _bytes_feature(np.array(array.shape).tobytes())
                            feature[f"{key}_dtype"] = _bytes_feature(str(array.dtype).encode())
                
                # Create example and write to file
                example = tf.train.Example(features=tf.train.Features(feature=feature))
                writer.write(example.SerializeToString())
    
    logger.info(f"Exported {num_examples} examples to {output_path}")
    return output_path

def import_from_tfrecord(
    tfrecord_path: str,
    metadata: Dict[str, Any] = None
) -> Dict[str, Any]:
    """
    Import data from TFRecord format.
    
    Args:
        tfrecord_path: Path to TFRecord file
        metadata: Optional metadata with shape and dtype information
        
    Returns:
        Dictionary with imported data
    """
    try:
        import tensorflow as tf
        import numpy as np
    except ImportError:
        logger.error("Failed to import tensorflow. Install with 'pip install tensorflow'")
        raise
    
    if not os.path.exists(tfrecord_path):
        raise FileNotFoundError(f"TFRecord file not found: {tfrecord_path}")
    
    # Define parsing function
    def _parse_function(example_proto):
        # Define features dynamically based on metadata
        features = {}
        shape_features = {}
        dtype_features = {}
        
        if metadata and 'features' in metadata:
            for feature_name in metadata['features']:
                features[feature_name] = tf.io.FixedLenFeature([], tf.string)
                shape_features[f"{feature_name}_shape"] = tf.io.FixedLenFeature([], tf.string)
                dtype_features[f"{feature_name}_dtype"] = tf.io.FixedLenFeature([], tf.string)
        else:
            # If no metadata, parse dynamically (less efficient)
            logger.warning("No metadata provided, parsing TFRecord dynamically")
            
            # Try to parse first example to get feature structure
            raw_dataset = tf.data.TFRecordDataset([tfrecord_path])
            for raw_record in raw_dataset.take(1):
                example = tf.train.Example()
                example.ParseFromString(raw_record.numpy())
                
                for key in example.features.feature:
                    if key.endswith('_shape') or key.endswith('_dtype'):
                        continue
                    
                    if example.features.feature[key].bytes_list.value:
                        features[key] = tf.io.FixedLenFeature([], tf.string)
                    elif example.features.feature[key].int64_list.value:
                        features[key] = tf.io.FixedLenFeature([], tf.int64)
                    
                    # Add shape and dtype features if they exist
                    if f"{key}_shape" in example.features.feature:
                        shape_features[f"{key}_shape"] = tf.io.FixedLenFeature([], tf.string)
                    if f"{key}_dtype" in example.features.feature:
                        dtype_features[f"{key}_dtype"] = tf.io.FixedLenFeature([], tf.string)
        
        # Combine all features
        parse_features = {**features, **shape_features, **dtype_features}
        
        # Parse example
        parsed_features = tf.io.parse_single_example(example_proto, parse_features)
        
        # Process each feature
        result = {}
        for feature_name in features:
            # Get array bytes
            array_bytes = parsed_features[feature_name]
            
            # Get shape if available
            if f"{feature_name}_shape" in parsed_features:
                shape_bytes = parsed_features[f"{feature_name}_shape"]
                shape = tf.io.decode_raw(shape_bytes, tf.int64)
                shape = tf.reshape(shape, [-1]).numpy()
            else:
                # Default to unknown shape
                shape = [-1]
            
            # Get dtype if available
            if f"{feature_name}_dtype" in parsed_features:
                dtype_str = parsed_features[f"{feature_name}_dtype"]
                dtype_str = dtype_str.numpy().decode('utf-8')
                dtype = np.dtype(dtype_str)
            else:
                # Default to float32
                dtype = np.float32
            
            # Decode array
            try:
                array = tf.io.decode_raw(array_bytes, dtype)
                array = tf.reshape(array, shape).numpy()
                result[feature_name] = array
            except Exception as e:
                logger.error(f"Error decoding feature {feature_name}: {e}")
        
        return result
    
    # Create dataset
    dataset = tf.data.TFRecordDataset([tfrecord_path])
    parsed_dataset = dataset.map(_parse_function)
    
    # Convert to dictionary of numpy arrays
    arrays = {}
    for i, example in enumerate(parsed_dataset):
        for key, value in example.items():
            if key not in arrays:
                arrays[key] = []
            arrays[key].append(value)
    
    # Stack arrays
    result = {}
    for key, value_list in arrays.items():
        try:
            result[key] = np.stack(value_list)
        except Exception as e:
            logger.error(f"Error stacking arrays for {key}: {e}")
    
    logger.info(f"Imported data from {tfrecord_path} with {len(next(iter(result.values())))} examples")
    return result 