#!/usr/bin/env python
"""
Refactored TPU Hardware Access Test Script

This script verifies that TensorFlow can properly access the TPU hardware on a Cloud TPU VM.
It assumes that:
  - The TPU VM is configured with the correct environment settings.
  - The TPU driver (libtpu.so) is available at /lib/libtpu.so.
  - TPU_NAME is set to 'local' so that the local TPU device is used.
  - TPU_LOAD_LIBRARY is set to '0' to prevent redundant loading.
  
It runs a simple computation on the TPU using TensorFlow and reports detailed diagnostics.
"""

import os
import sys
import time
import logging
import traceback
from pathlib import Path

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("TPU-Verify")

def ensure_tpu_env():
    """Ensure necessary TPU environment variables are set with recommended defaults."""
    # Use 'local' since on TPU VMs the TPU is available locally.
    os.environ.setdefault("TPU_NAME", "local")
    # Avoid re-loading the driver; this is recommended on TPU VMs (and pods)
    os.environ.setdefault("TPU_LOAD_LIBRARY", "0")
    # Set the TPU driver library path – ensure your image or volume mount provides this file.
    os.environ.setdefault("TF_PLUGGABLE_DEVICE_LIBRARY_PATH", "/lib/libtpu.so")
    logger.info("Environment settings:")
    logger.info(f"TPU_NAME={os.environ['TPU_NAME']}")
    logger.info(f"TPU_LOAD_LIBRARY={os.environ['TPU_LOAD_LIBRARY']}")
    logger.info(f"TF_PLUGGABLE_DEVICE_LIBRARY_PATH={os.environ['TF_PLUGGABLE_DEVICE_LIBRARY_PATH']}")

def find_tpu_driver():
    """Check that the TPU driver exists at the expected location."""
    driver_path = os.environ.get("TF_PLUGGABLE_DEVICE_LIBRARY_PATH", "/lib/libtpu.so")
    if Path(driver_path).exists():
        logger.info(f"Found TPU driver at: {driver_path}")
        return driver_path
    else:
        logger.warning(
            f"TPU driver not found at {driver_path}. Ensure libtpu.so is available (mounted or installed) in your container."
        )
        return None

def print_environment():
    """Print relevant TPU-related environment variables."""
    logger.info("=== TPU Environment Variables ===")
    for key in sorted(os.environ):
        if any(x in key for x in ["TPU", "PJRT", "XLA", "TF_PLUGGABLE", "TPU_LOAD_LIBRARY"]):
            logger.info(f"{key}={os.environ[key]}")
    logger.info("===============================")

def run_diagnostics():
    """Run basic diagnostics for TPU setup."""
    logger.info("Running diagnostics...")
    # Check if the TPU driver is present.
    driver = find_tpu_driver()
    if not driver:
        logger.error("Diagnostics: libtpu.so not found. TPU access will likely fail.")
    else:
        logger.info("Diagnostics: libtpu.so is available.")
    # Optionally, check the cloud environment (works on GCP only)
    try:
        import urllib.request
        req = urllib.request.Request(
            "http://metadata.google.internal/computeMetadata/v1/instance/",
            headers={"Metadata-Flavor": "Google"},
        )
        with urllib.request.urlopen(req, timeout=5) as response:
            if response.status == 200:
                logger.info("Diagnostics: Running in Google Cloud environment.")
    except Exception as e:
        logger.info(f"Diagnostics: Not running in Google Cloud or unable to access metadata: {e}")

def main():
    """Main function to verify TPU hardware access using TensorFlow."""
    logger.info("Starting TPU verification and hardware access test")
    
    # Ensure environment variables are set properly.
    ensure_tpu_env()
    
    # Check that the TPU driver is available.
    driver_path = find_tpu_driver()
    if driver_path:
        os.environ["TF_PLUGGABLE_DEVICE_LIBRARY_PATH"] = driver_path
    else:
        logger.warning("Proceeding without confirmed TPU driver; TPU access may fail.")
    
    # Print environment information.
    print_environment()
    
    try:
        logger.info("Importing TensorFlow...")
        start_time = time.time()
        import tensorflow as tf
        logger.info(f"TensorFlow imported in {time.time() - start_time:.2f} seconds")
        
        logger.info(f"TensorFlow version: {tf.__version__}")
        logger.info(f"Python version: {sys.version}")
        
        # List available TPU devices.
        logger.info("Listing TPU devices...")
        tpu_devices = tf.config.list_physical_devices("TPU")
        logger.info(f"Number of TPU devices found: {len(tpu_devices)}")
        for device in tpu_devices:
            logger.info(f"TPU device: {device}")
        
        if not tpu_devices:
            logger.error("No TPU devices found. Check TPU configuration.")
            run_diagnostics()
            return False
        
        # Create a TPU distribution strategy.
        logger.info("Creating TPU distribution strategy...")
        start_time = time.time()
        try:
            strategy = tf.distribute.TPUStrategy()
            logger.info(f"TPU strategy created in {time.time() - start_time:.2f} seconds")
        except Exception as e:
            logger.error(f"Failed to create TPU strategy: {e}")
            logger.error(traceback.format_exc())
            run_diagnostics()
            return False
        
        # Run a simple computation on the TPU.
        logger.info("Running computation on TPU...")
        with strategy.scope():
            model = tf.keras.Sequential([
                tf.keras.layers.Dense(10, activation="relu", input_shape=(5,)),
                tf.keras.layers.Dense(1)
            ])
            model.compile(optimizer="adam", loss="mse")
            logger.info("Model compiled successfully.")
            
            # Generate random test data.
            x = tf.random.normal((1000, 5))
            y = tf.random.normal((1000, 1))
            logger.info("Starting model training...")
            train_start = time.time()
            model.fit(x, y, epochs=2, batch_size=32, verbose=1)
            logger.info(f"Model training completed in {time.time() - train_start:.2f} seconds")
        
        # Run a direct computation using tf.function.
        logger.info("Running direct computation using tf.function...")
        @tf.function
        def simple_computation():
            a = tf.ones((8, 8)) * 5.0
            b = tf.ones((8, 8)) * 3.0
            return tf.matmul(a, b) + a
        
        comp_start = time.time()
        result = strategy.run(simple_computation)
        logger.info(f"Direct computation completed in {time.time() - comp_start:.4f} seconds")
        logger.info(f"Computation result shape: {result.shape}")
        
        logger.info("TPU hardware access test PASSED!")
        logger.info("Your code can successfully access the TPU hardware.")
        return True
        
    except ImportError as e:
        logger.error(f"Failed to import TensorFlow: {e}")
        logger.error("Ensure TensorFlow is installed with TPU support.")
        run_diagnostics()
        return False
        
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        logger.error(traceback.format_exc())
        run_diagnostics()
        return False

if __name__ == "__main__":
    success = main()
    sys.exit(0 if success else 1) 