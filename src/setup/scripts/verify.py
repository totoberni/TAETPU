#!/usr/bin/env python3
"""
TPU Verification and Hello World Script

This script provides two main functions:
1. verify_tpu() - Verifies that PyTorch can connect to the TPU device
2. hello_world() - Runs a simple PyTorch example on the TPU

Both functions demonstrate TPU connectivity and functionality.
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
    
    # Ensure PJRT_DEVICE environment variable is set
    if 'PJRT_DEVICE' not in os.environ:
        print("Setting PJRT_DEVICE=TPU")
        os.environ['PJRT_DEVICE'] = 'TPU'
    
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

def hello_world():
    """Run a simple PyTorch example on the TPU."""
    print("="*50)
    print("Hello World from Google Cloud TPU!")
    print("="*50)
    
    # Ensure PJRT_DEVICE environment variable is set
    if 'PJRT_DEVICE' not in os.environ:
        print("Setting PJRT_DEVICE=TPU")
        os.environ['PJRT_DEVICE'] = 'TPU'
    
    # Import PyTorch and torch_xla
    try:
        import torch_xla
        import torch_xla.core.xla_model as xm
        
        print(f"PyTorch version: {torch.__version__}")
        print(f"PyTorch-XLA version: {torch_xla.__version__}")
        
        # List available TPU devices
        devices = xm.get_xla_supported_devices()
        print(f"Available TPU devices: {devices}")
        
        if not devices:
            print("WARNING: No TPU devices found!")
            return False
            
        # Get the XLA device
        device = xm.xla_device()
        print(f"Using XLA device: {device}")
        
        # Create tensors on the TPU device
        t1 = torch.randn(3, 3, device=device)
        t2 = torch.randn(3, 3, device=device)
        
        # Perform a simple operation
        result = t1 + t2
        print("\nTensor addition result:")
        print(result)
        
        # Demonstrate that computation is actually performed on the TPU
        result = result * 2
        print("\nScaled result (x2):")
        print(result)
        
        print("\nHello World computation successful on TPU!")
        return True
        
    except Exception as e:
        print(f"Error during TPU computation: {e}")
        print("\nThis may be resolved by:")
        print("1. Ensuring the Docker container has --privileged flag")
        print("2. Setting PJRT_DEVICE=TPU environment variable")
        print("3. Running Docker with proper TPU access")
        print("4. Checking if the TPU is healthy with 'gcloud compute tpus tpu-vm describe'")
        return False

def run_all_tests():
    """Run all TPU tests sequentially."""
    # First verify TPU accessibility
    verification_result = verify_tpu()
    
    if not verification_result:
        print("\nBasic TPU verification failed. Aborting hello world test.")
        return False
    
    print("\n" + "="*50)
    print("Basic verification passed, proceeding to hello world test...")
    print("="*50 + "\n")
    
    # If verification passed, run hello world
    hello_result = hello_world()
    
    if verification_result and hello_result:
        print("\nAll TPU tests PASSED! Your TPU environment is ready.")
        return True
    else:
        print("\nSome TPU tests FAILED. Please check the logs above.")
        return False

if __name__ == "__main__":
    # Check for specific function to run
    if len(sys.argv) > 1:
        if sys.argv[1] == "verify":
            success = verify_tpu()
        elif sys.argv[1] == "hello":
            success = hello_world()
        elif sys.argv[1] == "all":
            success = run_all_tests()
        else:
            print(f"Unknown command: {sys.argv[1]}")
            print("Available commands: verify, hello, all")
            success = False
    else:
        # Default to run all tests
        success = run_all_tests()
    
    sys.exit(0 if success else 1) 