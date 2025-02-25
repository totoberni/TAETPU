"""
Hello World example for Google Cloud TPU with PyTorch
This script verifies that PyTorch can connect to the TPU device
and perform basic operations.
"""
import os
import sys

def hello_world():
    print("Hello World from Google Cloud TPU!")
    
    # Ensure PJRT_DEVICE environment variable is set
    if 'PJRT_DEVICE' not in os.environ:
        print("Setting PJRT_DEVICE=TPU")
        os.environ['PJRT_DEVICE'] = 'TPU'
    
    # Import PyTorch and torch_xla
    import torch
    import torch_xla
    import torch_xla.core.xla_model as xm
    
    print(f"PyTorch version: {torch.__version__}")
    print(f"PyTorch-XLA version: {torch_xla.__version__}")
    
    # List available TPU devices
    try:
        # Attempt to get TPU devices (without devkind parameter)
        devices = xm.get_xla_supported_devices()
        print(f"Available TPU devices: {devices}")
        
        if not devices:
            print("WARNING: No TPU devices found!")
            sys.exit(1)
            
    except Exception as e:
        print(f"Error detecting TPU devices: {e}")
        print("\nThis may be resolved by:")
        print("1. Ensuring the Docker container has --privileged flag")
        print("2. Setting PJRT_DEVICE=TPU environment variable")
        print("3. Running Docker with proper TPU access")
        print("4. Checking if the TPU is healthy with 'gcloud compute tpus tpu-vm describe'")
        sys.exit(1)
    
    try:
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
    except Exception as e:
        print(f"Error during TPU computation: {e}")
        sys.exit(1)

if __name__ == "__main__":
    hello_world()