#!/usr/bin/env python3
"""
TPU Verification and Hello World Script

This script provides two main functions:
1. verify_tpu() - Verifies that TensorFlow can connect to the TPU device
2. hello_world() - Runs a simple TensorFlow example on the TPU

Both functions demonstrate TPU connectivity and functionality.
"""
import os
import sys
import tensorflow as tf

def verify_tpu():
    """Verify TPU is accessible and working properly."""
    print("="*50)
    print("TPU Verification Script")
    print("="*50)
    
    # Print environment information
    print("\nEnvironment Information:")
    print(f"- TF_CPP_MIN_LOG_LEVEL = {os.environ.get('TF_CPP_MIN_LOG_LEVEL', 'Not set')}")
    print(f"- LD_LIBRARY_PATH = {os.environ.get('LD_LIBRARY_PATH', 'Not set')}")
    
    # Print TensorFlow version
    print(f"\nTensorFlow version: {tf.__version__}")
    
    try:
        # Try to detect TPU
        print("\nChecking for TPU devices...")
        tpu = tf.distribute.cluster_resolver.TPUClusterResolver()
        print(f"TPU: {tpu.cluster_spec().as_dict()}")
        
        # Connect to the TPU
        print("Connecting to TPU...")
        tf.config.experimental_connect_to_cluster(tpu)
        
        # Initialize TPU system
        print("Initializing TPU system...")
        tf.tpu.experimental.initialize_tpu_system(tpu)
        
        # Check available TPU devices
        print("\nListing TPU devices...")
        tpu_devices = tf.config.list_logical_devices('TPU')
        print(f"Available TPU devices: {tpu_devices}")
        
        if not tpu_devices:
            print("\nWARNING: No TPU devices found!")
            print("Troubleshooting suggestions:")
            print("1. Ensure Docker is running with --privileged flag")
            print("2. Check if TPU device exists at /dev/accel*")
            print("3. Verify TPU health with 'gcloud compute tpus tpu-vm describe'")
            return False
        
        # Create TPU distribution strategy
        print("\nCreating TPU distribution strategy...")
        strategy = tf.distribute.TPUStrategy(tpu)
        print(f"TPU strategy created: {strategy}")
        
        # Try basic tensor operations
        print("\nPerforming basic tensor operation...")
        with strategy.scope():
            t = tf.random.normal([3, 3])
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
        print("4. Ensure the TPU runtime is compatible with your TensorFlow version")
        return False

def hello_world():
    """Run a simple TensorFlow example on the TPU."""
    print("="*50)
    print("Hello World from Google Cloud TPU!")
    print("="*50)
    
    # Import TensorFlow
    try:
        print(f"TensorFlow version: {tf.__version__}")
        
        # Detect and connect to TPU
        tpu = tf.distribute.cluster_resolver.TPUClusterResolver()
        print(f"TPU: {tpu.cluster_spec().as_dict()}")
        
        # Connect to the TPU
        tf.config.experimental_connect_to_cluster(tpu)
        
        # Initialize TPU system
        tf.tpu.experimental.initialize_tpu_system(tpu)
        
        # List available TPU devices
        tpu_devices = tf.config.list_logical_devices('TPU')
        print(f"Available TPU devices: {tpu_devices}")
        
        if not tpu_devices:
            print("WARNING: No TPU devices found!")
            return False
            
        # Create TPU distribution strategy
        strategy = tf.distribute.TPUStrategy(tpu)
        print(f"TPU strategy created: {strategy}")
        
        # Perform computation in TPU strategy scope
        with strategy.scope():
            # Create tensors
            t1 = tf.random.normal([3, 3])
            t2 = tf.random.normal([3, 3])
            
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
        print("2. Running Docker with proper TPU access")
        print("3. Checking if the TPU is healthy with 'gcloud compute tpus tpu-vm describe'")
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