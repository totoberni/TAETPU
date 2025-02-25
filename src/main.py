"""
Hello World example for Google Cloud TPU with PyTorch
This script verifies that PyTorch can connect to the TPU device
and perform basic operations.
"""

def hello_world():
    print("Hello World from Google Cloud TPU!")
    
    # Import PyTorch and torch_xla
    import torch
    import torch_xla
    import torch_xla.core.xla_model as xm
    
    print(f"PyTorch version: {torch.__version__}")
    print(f"PyTorch-XLA version: {torch_xla.__version__}")
    
    # List available TPU devices
    print(f"Available TPU devices: {xm.get_xla_supported_devices('TPU')}")
    
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

if __name__ == "__main__":
    hello_world()