"""
Example file for TPU development with Docker volume mounting.

This file demonstrates how to create code that can be mounted and run
on the TPU Docker container without rebuilding the image.
"""
import os
import torch

def mounted_example():
    """Simple function to demonstrate mounted code execution on TPU."""
    print("="*50)
    print("Running mounted code on TPU")
    print("="*50)
    
    # Print current working directory and environment to verify mounting
    print(f"Current directory: {os.getcwd()}")
    print(f"Directory contents: {os.listdir()}")
    
    # Check if running on a TPU (requires torch_xla)
    try:
        import torch_xla
        import torch_xla.core.xla_model as xm
        
        # Get device (TPU)
        device = xm.xla_device()
        print(f"XLA device: {device}")
        
        # Create and manipulate tensors to verify TPU execution
        a = torch.ones(5, 5, device=device)
        b = a * 2
        c = a + b
        
        print("\nTensor operations successful:\n")
        print("===============EXTRA TEST===============")
        print(f"c = a + b = \n{c}")
        print(f"c.shape: {c.shape}")
        print(f"c.device: {c.device}")
        print(f"c.dtype: {c.dtype}")
        print(f"c.requires_grad: {c.requires_grad}")
        print(f"c.grad: {c.grad}")
        print(f"c.grad_fn: {c.grad_fn}")
        print("===============EXTRA TEST===============")
        print("\nMounted code execution successful!")
        
    except ImportError:
        print("Not running on TPU: torch_xla not available")
        return False
    except Exception as e:
        print(f"Error during TPU operation: {e}")
        return False
        
    return True

if __name__ == "__main__":
    mounted_example() 