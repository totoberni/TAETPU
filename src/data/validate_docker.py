#!/usr/bin/env python
"""
Validation script for Docker environment setup.

This script checks if the environment is correctly set up for data processing
within the Docker container. It validates:
1. Access to mounted directories
2. Import of required modules
3. Basic data operations with PyTorch and NumPy
4. TPU availability if running on TPU hardware

Usage:
    python validate_docker.py
"""

import os
import sys
import importlib
import platform
import tempfile
import inspect
import time
from pathlib import Path


def check_directory_access():
    """Check if all required directories are accessible."""
    required_dirs = [
        "/app/mount/src/configs",
        "/app/mount/src/datasets/raw",
        "/app/mount/src/datasets/clean/transformer",
        "/app/mount/src/datasets/clean/static",
        "/app/mount/src/cache/prep",
        "/app/mount/src/models/prep",
        "/app/mount/src/data",
    ]
    
    print("\n=== Directory Access Check ===")
    all_accessible = True
    
    for directory in required_dirs:
        exists = os.path.exists(directory)
        writable = False
        if exists:
            # Try to write a temporary file to check write access
            try:
                test_file = os.path.join(directory, ".test_write_access")
                with open(test_file, "w") as f:
                    f.write("test")
                os.remove(test_file)
                writable = True
            except Exception as e:
                writable = False
                print(f"  ERROR: Cannot write to {directory}: {e}")
        
        status = "PASS" if exists and writable else "FAIL"
        print(f"  {status}: {directory} - Exists: {exists}, Writable: {writable}")
        
        if not (exists and writable):
            all_accessible = False
    
    return all_accessible


def check_module_imports():
    """Check if all required modules can be imported."""
    required_modules = [
        "numpy",
        "torch",
        "yaml",
        "tqdm",
        "pandas",
        "sklearn",
        "transformers",
        "datasets",
    ]
    
    print("\n=== Module Import Check ===")
    all_importable = True
    
    for module_name in required_modules:
        try:
            module = importlib.import_module(module_name)
            version = getattr(module, "__version__", "Unknown")
            print(f"  PASS: {module_name} (version: {version})")
        except ImportError as e:
            print(f"  FAIL: {module_name} - {e}")
            all_importable = False
    
    # Check for special PyTorch/XLA import which is needed for TPU
    try:
        import torch_xla
        import torch_xla.core.xla_model as xm
        print(f"  PASS: torch_xla (available for TPU)")
    except ImportError:
        print(f"  WARNING: torch_xla not available - TPU functionality will be limited")
    
    return all_importable


def check_local_module_imports():
    """Check if all local modules can be imported."""
    local_modules = [
        "data_types",
        "process_utils",
        "process_static",
        "process_transformer",
        "data_import",
        "data_pipeline"
    ]
    
    print("\n=== Local Module Import Check ===")
    all_importable = True
    current_dir = os.path.dirname(os.path.abspath(__file__))
    
    # Add current directory to path if not already there
    if current_dir not in sys.path:
        sys.path.insert(0, current_dir)
    
    for module_name in local_modules:
        try:
            module = importlib.import_module(module_name)
            
            # Get module functions and classes
            functions = [name for name, obj in inspect.getmembers(module, inspect.isfunction)]
            classes = [name for name, obj in inspect.getmembers(module, inspect.isclass)]
            
            print(f"  PASS: {module_name} - Found {len(functions)} functions, {len(classes)} classes")
        except ImportError as e:
            print(f"  FAIL: {module_name} - {e}")
            all_importable = False
    
    return all_importable


def check_basic_operations():
    """Check if basic data operations work correctly."""
    print("\n=== Basic Operations Check ===")
    
    try:
        import numpy as np
        import torch
        
        # NumPy operations
        arr = np.random.rand(100, 100)
        result = arr.mean()
        print(f"  PASS: NumPy operations (created array of shape {arr.shape})")
        
        # PyTorch CPU operations
        t = torch.rand(100, 100)
        result = t.mean()
        print(f"  PASS: PyTorch CPU operations (created tensor of shape {t.shape})")
        
        # Try PyTorch/XLA operations if available
        try:
            import torch_xla.core.xla_model as xm
            
            # Check if TPU is available without actually trying to use it
            devices = xm.get_xla_supported_devices()
            if devices and any('TPU' in str(d).upper() for d in devices):
                print(f"  PASS: PyTorch/XLA detected TPU devices: {devices}")
            else:
                print(f"  INFO: No TPU devices detected by PyTorch/XLA. Found: {devices}")
                
        except ImportError:
            print("  INFO: PyTorch/XLA operations skipped (not available)")
        
        return True
        
    except Exception as e:
        print(f"  FAIL: Basic operations check failed: {e}")
        return False


def check_file_io():
    """Check if file I/O operations work correctly in the mounted directories."""
    print("\n=== File I/O Check ===")
    
    mount_dir = "/app/mount/src"
    test_subdir = "cache/prep"  # Use cache dir for test files
    test_dir = os.path.join(mount_dir, test_subdir)
    
    if not os.path.exists(test_dir):
        try:
            os.makedirs(test_dir, exist_ok=True)
            print(f"  PASS: Created test directory {test_dir}")
        except Exception as e:
            print(f"  FAIL: Cannot create test directory {test_dir}: {e}")
            return False
    
    # Try writing and reading a small test file
    test_file = os.path.join(test_dir, "docker_validate_test.txt")
    try:
        # Write test file
        with open(test_file, "w") as f:
            f.write("Docker validation test - " + time.strftime("%Y-%m-%d %H:%M:%S"))
        print(f"  PASS: Wrote test file {test_file}")
        
        # Read test file
        with open(test_file, "r") as f:
            content = f.read()
        print(f"  PASS: Read test file: {content}")
        
        # Cleanup
        os.remove(test_file)
        print(f"  PASS: Removed test file")
        
        return True
        
    except Exception as e:
        print(f"  FAIL: File I/O check failed: {e}")
        return False


def check_data_types_module():
    """Check if the data_types module works correctly."""
    print("\n=== Data Types Module Check ===")
    
    try:
        # Make sure we're in the right directory
        current_dir = os.path.dirname(os.path.abspath(__file__))
        if current_dir not in sys.path:
            sys.path.insert(0, current_dir)
        
        from data_types import TransformerInput, TransformerTarget, StaticInput, StaticTarget
        import numpy as np
        
        # Create a simple TransformerInput
        input_ids = np.array([1, 2, 3, 4, 5])
        attention_mask = np.array([1, 1, 1, 1, 1])
        transformer_input = TransformerInput(input_ids=input_ids, attention_mask=attention_mask)
        
        # Convert to tensors
        tensors = transformer_input.to_tensors()
        print(f"  PASS: Created TransformerInput and converted to tensors")
        
        # Create a simple StaticInput
        center_words = np.array([1, 2, 3])
        context_words = np.array([[4, 5], [6, 7], [8, 9]])
        context_mask = np.array([[1, 1], [1, 1], [1, 1]])
        static_input = StaticInput(center_words=center_words, context_words=context_words, context_mask=context_mask)
        
        # Convert to tensors
        tensors = static_input.to_tensors()
        print(f"  PASS: Created StaticInput and converted to tensors")
        
        return True
        
    except Exception as e:
        print(f"  FAIL: Data types module check failed: {e}")
        import traceback
        traceback.print_exc()
        return False


def main():
    """Run all validation checks."""
    print("=== Docker Environment Validation ===")
    print(f"Python version: {platform.python_version()}")
    print(f"Platform: {platform.platform()}")
    print(f"Current directory: {os.getcwd()}")
    
    # Run all checks
    dir_check = check_directory_access()
    module_check = check_module_imports()
    local_module_check = check_local_module_imports()
    op_check = check_basic_operations()
    file_check = check_file_io()
    data_types_check = check_data_types_module()
    
    # Summary
    print("\n=== Validation Summary ===")
    print(f"Directory Access: {'PASS' if dir_check else 'FAIL'}")
    print(f"Module Imports: {'PASS' if module_check else 'FAIL'}")
    print(f"Local Module Imports: {'PASS' if local_module_check else 'FAIL'}")
    print(f"Basic Operations: {'PASS' if op_check else 'FAIL'}")
    print(f"File I/O: {'PASS' if file_check else 'FAIL'}")
    print(f"Data Types Module: {'PASS' if data_types_check else 'FAIL'}")
    
    all_passed = dir_check and module_check and local_module_check and op_check and file_check and data_types_check
    print(f"\nOverall: {'PASS' if all_passed else 'FAIL'}")
    
    return 0 if all_passed else 1


if __name__ == "__main__":
    sys.exit(main()) 