import os
import time
import torch
import torch_xla.core.xla_model as xm
import torch_xla.debug.profiler as xp
from loguru import logger
from contextlib import contextmanager
from pytorch_memlab import MemReporter

class ModelProfiler:
    """Comprehensive profiler for PyTorch models on TPU"""
    
    def __init__(self, model, log_dir="logs/profiler"):
        self.model = model
        self.log_dir = log_dir
        os.makedirs(log_dir, exist_ok=True)
        self.mem_reporter = MemReporter(model)
        self.profiling_enabled = False
    
    @contextmanager
    def profile_step(self, name="forward_backward"):
        """Context manager to profile a single step of training or inference"""
        start_time = time.time()
        try:
            yield
        finally:
            duration = time.time() - start_time
            logger.info(f"{name} step completed in {duration:.4f}s")
    
    def profile_memory(self, prefix=""):
        """Report memory usage of the model"""
        logger.info(f"{prefix} Memory Report:")
        self.mem_reporter.report()
    
    def start_profiling(self, name="profile"):
        """Start PyTorch/XLA profiling"""
        if not self.profiling_enabled:
            self.profile_name = f"{name}_{time.strftime('%Y%m%d_%H%M%S')}"
            xp.start_server(port=9012)
            xp.trace_on(self.log_dir, self.profile_name)
            self.profiling_enabled = True
            logger.info(f"Profiling started: {self.profile_name}")
    
    def stop_profiling(self):
        """Stop PyTorch/XLA profiling and save results"""
        if self.profiling_enabled:
            xp.trace_off()
            self.profiling_enabled = False
            profile_path = os.path.join(self.log_dir, f"{self.profile_name}.json")
            logger.info(f"Profiling data saved to: {profile_path}")
            logger.info("To view the profile: tensorboard --logdir=logs/profiler")
    
    def profile_operation(self, operation_fn, input_data, name="operation", 
                         num_repeats=10, warmup=3):
        """Profile a specific operation with timing information"""
        # Warmup
        for _ in range(warmup):
            operation_fn(input_data)
            xm.mark_step()
        
        # Actual profiling
        start = time.time()
        for i in range(num_repeats):
            with self.profile_step(f"{name}_{i}"):
                operation_fn(input_data)
                xm.mark_step()
        
        avg_time = (time.time() - start) / num_repeats
        logger.info(f"Average time for {name}: {avg_time:.4f}s over {num_repeats} runs")
        return avg_time

# Decorator for profiling individual functions
def profile_function(fn=None, *, name=None):
    """Decorator to profile a function execution time"""
    def decorator(func):
        def wrapper(*args, **kwargs):
            func_name = name or func.__name__
            start_time = time.time()
            result = func(*args, **kwargs)
            duration = time.time() - start_time
            logger.info(f"Function {func_name} took {duration:.4f}s to execute")
            return result
        return wrapper
    
    if fn:
        return decorator(fn)
    return decorator 