"""Transformer Ablation Experiment Models Package.

This package provides model-related utilities, including:
- Model saving and loading functionalities with TPU optimization
- Support for both transformer and static embedding model types
- Pretrained model loaders with HuggingFace integration
- Configurable serialization for experiment tracking
"""

import os
import logging
import torch
from pathlib import Path
from typing import Any, Dict, Optional, Tuple, Union

# Configure logging
logger = logging.getLogger(__name__)

# Import functions from parent package with relative imports
from ..utils import (
    ensure_directories_exist,
    handle_errors, 
    safe_operation
)

# Import DATA_PATHS from configs instead of utils
from ..configs import DATA_PATHS

from ..tpu import (
    optimize_tensor_dimensions,
    is_tpu_available,
    get_optimal_batch_size
)

# Create models directory if it doesn't exist
os.makedirs(DATA_PATHS.get('MODELS_DIR', os.path.join(os.path.dirname(__file__), 'saved')), exist_ok=True)

@safe_operation("model saving", default_return=None)
def save_model(
    model: Any, 
    model_name: str, 
    output_dir: Optional[str] = None, 
    optimize_for_tpu: bool = False, 
    extra_data: Optional[Dict[str, Any]] = None
) -> Optional[str]:
    """
    Save a model to disk with optional TPU optimization.
    
    Args:
        model: The model to save
        model_name: Name of the model
        output_dir: Directory to save to (uses default if None)
        optimize_for_tpu: Whether to optimize for TPU deployment
        extra_data: Additional data to save with the model (dict)
        
    Returns:
        Path to the saved model or None if saving failed
    """
    output_dir = output_dir or DATA_PATHS.get('MODELS_DIR', os.path.join(os.path.dirname(__file__), 'saved'))
    ensure_directories_exist([output_dir])
    
    # Prepare model filename
    filename = f"{model_name}.pt"
    full_path = os.path.join(output_dir, filename)
    
    # Prepare save data with model state dict
    save_data = {
        'model_state_dict': model.state_dict(),
        'model_config': getattr(model, 'config', {}),
        'metadata': {
            'model_name': model_name,
            'optimized_for_tpu': optimize_for_tpu,
            'saved_at': str(Path(full_path).stat().st_mtime if os.path.exists(full_path) else None)
        }
    }
    
    # Add any extra data
    if extra_data and isinstance(extra_data, dict):
        save_data.update(extra_data)
    
    # Save the model
    torch.save(save_data, full_path)
    logger.info(f"Model saved to {full_path}")
    return full_path

@safe_operation("model loading", default_return=(None, None))
def load_model(
    model_class: Any, 
    model_path_or_name: str, 
    device: Optional[Any] = None
) -> Tuple[Optional[Any], Optional[Dict[str, Any]]]:
    """
    Load a model from disk.
    
    Args:
        model_class: The model class to instantiate
        model_path_or_name: Path to model file or model name
        device: Device to load the model to
        
    Returns:
        Tuple of (loaded model instance, extra data) or (None, None) if loading failed
    """
    # Determine if input is a path or model name
    if os.path.isfile(model_path_or_name):
        model_path = model_path_or_name
    else:
        # Assume it's a model name and construct path
        models_dir = DATA_PATHS.get('MODELS_DIR', os.path.join(os.path.dirname(__file__), 'saved'))
        model_path = os.path.join(models_dir, f"{model_path_or_name}.pt")
    
    # Check if model exists
    if not os.path.exists(model_path):
        logger.error(f"Model file not found: {model_path}")
        return None, None
    
    # Determine device to load model to
    if device is None:
        device = torch.device('cuda' if torch.cuda.is_available() else 'cpu')
        if is_tpu_available():
            import torch_xla.core.xla_model as xm
            device = xm.xla_device()
    
    # Load model data
    model_data = torch.load(model_path, map_location=device)
    model_state = model_data.get('model_state_dict')
    model_config = model_data.get('model_config', {})
    
    # Create model instance
    model = model_class(**model_config)
    model.load_state_dict(model_state)
    model.to(device)
    model.eval()  # Set to evaluation mode by default
    
    # Extract any extra data
    extra_data = {k: v for k, v in model_data.items() 
                 if k not in ['model_state_dict', 'model_config', 'metadata']}
    
    logger.info(f"Model loaded from {model_path}")
    return model, extra_data

def load_pretrained_model(model_name: str, model_dir: str) -> Any:
    """
    Load pretrained model from disk or Hugging Face.
    
    Args:
        model_name: Name or path of model to load
        model_dir: Local directory to search for model
        
    Returns:
        Loaded model
    """
    try:
        from transformers import AutoModel
        
        # Try to load from local directory first
        local_path = os.path.join(model_dir, model_name)
        if os.path.exists(local_path):
            logger.info(f"Loading model from local path: {local_path}")
            return AutoModel.from_pretrained(local_path)
        
        # Otherwise load from Hugging Face
        logger.info(f"Loading model from Hugging Face: {model_name}")
        return AutoModel.from_pretrained(model_name)
    
    except ImportError:
        logger.error("transformers library is not installed. Install with 'pip install transformers'")
        raise
    except Exception as e:
        logger.error(f"Error loading model {model_name}: {e}")
        raise

# Import submodules - use relative import
from .prep import *

# Export subpackages and functions
__all__ = [
    'prep',
    'save_model',
    'load_model',
    'load_pretrained_model'
] 