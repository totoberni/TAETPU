#!/usr/bin/env python3
"""
TPU verification script that safely initializes and tests TPU functionality.
This script is designed to prevent segfaults by properly initializing the TPU.
"""

import os
import sys
import time
import tensorflow as tf

def main():
    """Main function to verify TPU functionality."""
    print("\n" + "="*80)
    print("TPU Verification Script")
    print("="*80 + "\n")
    
    # Print TensorFlow version
    print(f"TensorFlow version: {tf.__version__}")
    
    # Check environment variables
    print("\nChecking TPU environment variables:")
    env_vars = [
        "TPU_NAME", "PJRT_DEVICE", "TF_PLUGGABLE_DEVICE_LIBRARY_PATH",
        "XRT_TPU_CONFIG", "NEXT_PLUGGABLE_DEVICE_USE_C_API"
    ]
    
    for var in env_vars:
        value = os.environ.get(var)
        if value:
            print(f"  ✓ {var} = {value}")
        else:
            print(f"  ✗ {var} not set!")
    
    # Check for TPU devices
    print("\nDetecting TPU devices...")
    try:
        physical_devices = tf.config.list_physical_devices()
        print(f"Available physical devices: {[device.name for device in physical_devices]}")
        
        tpu_devices = tf.config.list_logical_devices('TPU')
        if len(tpu_devices) > 0:
            print(f"  ✓ Found {len(tpu_devices)} TPU logical devices")
            for i, device in enumerate(tpu_devices):
                print(f"    - TPU {i}: {device}")
                
            # Try to use the TPU resolver (newer TF versions)
            try:
                print("\nInitializing TPU system...")
                resolver = tf.distribute.cluster_resolver.TPUClusterResolver()
                tf.config.experimental_connect_to_cluster(resolver)
                tf.tpu.experimental.initialize_tpu_system(resolver)
                print("  ✓ TPU system initialized successfully")
                
                tpu_strategy = tf.distribute.TPUStrategy(resolver)
                print(f"  ✓ TPU strategy created with {tpu_strategy.num_replicas_in_sync} replicas")
                
                # Run a simple computation on the TPU
                print("\nRunning simple computation on TPU...")
                
                @tf.function
                def simple_computation():
                    # Create a random matrix and compute its square
                    x = tf.random.normal([1000, 1000])
                    return tf.matmul(x, x)
                
                # Use the TPU strategy to run the computation
                with tpu_strategy.scope():
                    start_time = time.time()
                    result = tpu_strategy.run(simple_computation)
                    end_time = time.time()
                
                print(f"  ✓ Computation completed in {end_time - start_time:.4f} seconds")
                print(f"  ✓ Result shape: {result.shape}")
                print("\nTPU verification completed successfully!")
                
                return True
                
            except Exception as e:
                print(f"  ✗ Error initializing TPU system: {str(e)}")
        else:
            print("  ✗ No TPU devices found!")
            sys.exit(1)
    except Exception as e:
        print(f"  ✗ Error detecting TPU devices: {str(e)}")
        sys.exit(1)
        
    return False

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1) 