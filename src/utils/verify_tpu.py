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
        tpu_devices = tf.config.list_logical_devices('TPU')
        if len(tpu_devices) > 0:
            print(f"  ✓ Found {len(tpu_devices)} TPU devices")
            for i, device in enumerate(tpu_devices):
                print(f"    - TPU {i}: {device}")
        else:
            print("  ✗ No TPU devices found!")
            sys.exit(1)
    except Exception as e:
        print(f"  ✗ Error detecting TPU devices: {str(e)}")
        sys.exit(1)
    
    # Safely initialize TPU system
    print("\nInitializing TPU system...")
    try:
        resolver = tf.distribute.cluster_resolver.TPUClusterResolver()
        print(f"  ✓ TPU Cluster Resolver: {resolver.cluster_spec()}")
        
        print("  - Connecting to TPU cluster...")
        tf.config.experimental_connect_to_cluster(resolver)
        
        print("  - Initializing TPU system...")
        tf.tpu.experimental.initialize_tpu_system(resolver)
        
        print("  ✓ TPU system initialized successfully")
    except Exception as e:
        print(f"  ✗ Failed to initialize TPU system: {str(e)}")
        sys.exit(1)
    
    # Initialize TPU Strategy
    print("\nInitializing TPU Strategy...")
    try:
        strategy = tf.distribute.TPUStrategy(resolver)
        print(f"  ✓ TPU Strategy initialized with {strategy.num_replicas_in_sync} replicas")
    except Exception as e:
        print(f"  ✗ Failed to initialize TPU Strategy: {str(e)}")
        sys.exit(1)
    
    # Run a simple computation using TPU
    print("\nRunning simple computation on TPU...")
    try:
        with strategy.scope():
            @tf.function
            def simple_computation():
                x = tf.random.normal([8, 100])
                return tf.reduce_mean(tf.matmul(x, tf.transpose(x)))
            
            start_time = time.time()
            result = strategy.run(simple_computation)
            end_time = time.time()
            
            print(f"  ✓ Computation result: {result}")
            print(f"  ✓ Computation time: {(end_time - start_time)*1000:.2f} ms")
    except Exception as e:
        print(f"  ✗ Failed to run computation on TPU: {str(e)}")
        sys.exit(1)
    
    # Final success message
    print("\n" + "="*80)
    print("✓ TPU verification completed successfully!")
    print("="*80 + "\n")
    
    return 0

if __name__ == "__main__":
    sys.exit(main()) 