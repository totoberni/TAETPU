#!/usr/bin/env python3
"""
TPU Verification Script

This script verifies that PyTorch can connect to the TPU device
and perform basic verification of the TPU environment.
"""
import os
import sys
import torch

def verify_tpu():
    """Verify TPU is accessible and working properly."""
    print("="*50)
    print("TPU Verification Script")
    print("="*50)
    
    # Print environment information
    print("\nEnvironment Information:")
    print(f"- PJRT_DEVICE = {os.environ.get('PJRT_DEVICE', 'Not set')}")
    print(f"- XLA_USE_BF16 = {os.environ.get('XLA_USE_BF16', 'Not set')}")
    print(f"- TF_CPP_MIN_LOG_LEVEL = {os.environ.get('TF_CPP_MIN_LOG_LEVEL', 'Not set')}")
    print(f"- LD_LIBRARY_PATH = {os.environ.get('LD_LIBRARY_PATH', 'Not set')}")
    
    # Print PyTorch version
    print(f"\nPyTorch version: {torch.__version__}")
    
    try:
        # Import torch_xla
        import torch_xla
        import torch_xla.core.xla_model as xm
        
        print(f"PyTorch XLA version: {torch_xla.__version__}")
        
        # Get TPU devices - using the correct API without devkind
        print("\nChecking for TPU devices...")
        devices = xm.get_xla_supported_devices()
        print(f"Available TPU devices: {devices}")
        
        if not devices:
            print("\nWARNING: No TPU devices found!")
            print("Troubleshooting suggestions:")
            print("1. Ensure Docker is running with --privileged flag")
            print("2. Ensure PJRT_DEVICE=TPU is set")
            print("3. Check if TPU device exists at /dev/accel*")
            print("4. Verify TPU health with 'gcloud compute tpus tpu-vm describe'")
            return False
        
        # Try to get a device
        print("\nAttempting to acquire TPU device...")
        device = xm.xla_device()
        print(f"Using XLA device: {device}")
        
        # Try basic tensor operations
        print("\nPerforming basic tensor operation...")
        t = torch.randn(3, 3, device=device)
        result = t + t
        print(f"Addition successful, tensor shape: {result.shape}")
        
        print("\nTPU verification SUCCESSFUL! *")
        return True
        
    except Exception as e:
        print(f"\nTPU verification FAILED! X")
        print(f"Error: {e}")
        print("\nPlease check the following:")
        print("1. Ensure Docker container has --privileged flag and device mapping")
        print("2. Verify environment variables are correctly set")
        print("3. Check TPU health with Google Cloud CLI tools")
        print("4. Ensure the TPU runtime is compatible with your PyTorch/XLA version")
        return False

if __name__ == "__main__":
    success = verify_tpu()
    sys.exit(0 if success else 1) 