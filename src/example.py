#!/usr/bin/env python3
"""
Example script demonstrating TAETPU package usage.

This script shows how to use the main functionality of the TAETPU package,
including TPU configuration, optimization, and data processing.
"""

import os
import numpy as np
import logging
from pathlib import Path

# Import the TAETPU package
import src as taetpu

# Configure logger for this script
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("example")

def demonstrate_config_loading():
    """Demonstrate loading configuration from both YAML and environment variables."""
    # Load configuration with defaults
    config = taetpu.load_config()
    logger.info(f"Loaded configuration: {config.keys()}")
    
    # Display dataset configurations
    if 'datasets' in config:
        logger.info(f"Available datasets: {list(config['datasets'].keys())}")

def demonstrate_tpu_environment():
    """Demonstrate TPU environment setup and checking."""
    # Check if TPU is available
    tpu_available = taetpu.is_tpu_available()
    logger.info(f"TPU available: {tpu_available}")
    
    # Show TPU environment variables
    logger.info(f"TPU environment variables:")
    for key, value in taetpu.TPU_ENV_VARS.items():
        env_value = os.environ.get(key, 'Not set')
        logger.info(f"  {key}: {env_value}")
    
    # Get optimal batch size for current TPU
    optimal_batch = taetpu.get_optimal_batch_size(base_size=16)
    logger.info(f"Optimal batch size: {optimal_batch}")

def demonstrate_directory_structure():
    """Demonstrate checking standard directory structure."""
    logger.info("Checking standard directory structure:")
    
    for name, path in taetpu.DATA_PATHS.items():
        exists = os.path.exists(path)
        logger.info(f"  {name}: {path} - {'Exists' if exists else 'Missing'}")

def demonstrate_tpu_optimization():
    """Demonstrate TPU optimization utilities."""
    # Tensor shape optimization
    input_shapes = [
        (29, 513),
        (32, 512),
        [64, 127, 54],
        127
    ]
    
    logger.info("TPU tensor shape optimization examples:")
    for shape in input_shapes:
        optimized = taetpu.optimize_tensor_dimensions(shape)
        logger.info(f"  Original: {shape}, Optimized: {optimized}")
    
    # Create a test tensor
    if taetpu.is_tpu_available():
        try:
            import torch
            import torch_xla.core.xla_model as xm
            
            # Creating a tensor with TPU-optimized dimensions
            input_size = (29, 513)
            optimized_size = taetpu.optimize_tensor_dimensions(input_size)
            
            # Create tensor on TPU
            device = taetpu.get_tpu_device()
            tensor = torch.randn(optimized_size).to(device)
            logger.info(f"Successfully created tensor on TPU with shape {tensor.shape}")
            
        except ImportError:
            logger.warning("PyTorch or torch_xla not available")
    else:
        logger.info("Skipping TPU tensor creation as TPU is not available")

def run_basic_example():
    """Run a basic example of package functionality."""
    logger.info("=== TAETPU Package Demo ===")
    
    # Demonstrate each functionality
    demonstrate_config_loading()
    demonstrate_tpu_environment()
    demonstrate_directory_structure()
    demonstrate_tpu_optimization()
    
    logger.info("=== Demo Complete ===")

if __name__ == "__main__":
    run_basic_example() 