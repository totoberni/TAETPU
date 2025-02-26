from loguru import logger
import sys
import os
from rich.console import Console
from rich.progress import Progress, TextColumn, BarColumn, TimeElapsedColumn
from datetime import datetime
import traceback

# Try to import TPU-specific modules with proper error handling
try:
    import torch_xla.debug.metrics as met
    import torch_xla.core.xla_model as xm
    TPU_AVAILABLE = True
except ImportError:
    TPU_AVAILABLE = False
    logger.warning("TPU support not available. Some functions will be limited.")

# Try to import optional wandb
try:
    import wandb
    WANDB_AVAILABLE = True
except ImportError:
    WANDB_AVAILABLE = False
    logger.warning("Weights & Biases not available. W&B logging will be disabled.")

# Configure base logger
def setup_logger(log_level="INFO", log_file=None):
    """Configure Loguru logger with console and optional file outputs"""
    # Remove default handler
    logger.remove()
    
    # Add console handler with formatting
    logger.add(
        sys.stderr,
        format="<green>{time:YYYY-MM-DD HH:mm:ss}</green> | <level>{level: <8}</level> | <cyan>{name}</cyan>:<cyan>{function}</cyan>:<cyan>{line}</cyan> - <level>{message}</level>",
        level=log_level,
        colorize=True
    )
    
    # Add file handler if specified
    if log_file:
        os.makedirs(os.path.dirname(log_file), exist_ok=True)
        logger.add(
            log_file,
            format="{time:YYYY-MM-DD HH:mm:ss} | {level: <8} | {name}:{function}:{line} - {message}",
            level=log_level,
            rotation="100 MB",
            retention="30 days"
        )
    
    return logger

# Rich console for formatted output
console = Console()

# TPU Metrics collection
class TPUMetricsLogger:
    """Class to collect and log TPU performance metrics"""
    
    def __init__(self, log_dir="logs/tpu_metrics", wandb_enabled=False):
        self.log_dir = log_dir
        os.makedirs(log_dir, exist_ok=True)
        self.wandb_enabled = wandb_enabled and WANDB_AVAILABLE
        self.metrics_history = []
        
        if not TPU_AVAILABLE:
            logger.warning("TPU support not available. TPUMetricsLogger will have limited functionality.")
        
        if wandb_enabled and not WANDB_AVAILABLE:
            logger.warning("Wandb requested but not available. Install with 'pip install wandb'")
        
    def collect_metrics(self):
        """Collect current TPU metrics"""
        if not TPU_AVAILABLE:
            logger.warning("Cannot collect TPU metrics: TPU support not available")
            return {"error": "TPU support not available", "timestamp": datetime.now().isoformat()}
        
        try:
            metrics = met.metrics_report()
            
            # Add timestamp
            metrics['timestamp'] = datetime.now().isoformat()
            
            # Add device stats if available
            try:
                if xm.xrt_world_size() > 0:
                    metrics['device_count'] = xm.xrt_world_size()
                    metrics['device_type'] = xm.get_ordinal()
            except Exception as e:
                logger.warning(f"Failed to get TPU device stats: {e}")
                    
            self.metrics_history.append(metrics)
            return metrics
        except Exception as e:
            error_info = {"error": str(e), "timestamp": datetime.now().isoformat()}
            logger.error(f"Error collecting TPU metrics: {e}")
            logger.debug(traceback.format_exc())
            self.metrics_history.append(error_info)
            return error_info
    
    def log_metrics(self, step=None):
        """Log current metrics to console and wandb if enabled"""
        metrics = self.collect_metrics()
        
        # Skip if there was an error and return False
        if 'error' in metrics:
            console.print(f"[bold red]Error collecting TPU metrics: {metrics['error']}[/bold red]")
            return False
        
        # Log to console
        console.print("[bold blue]TPU Metrics:[/bold blue]")
        for key, value in metrics.items():
            if key != 'timestamp':
                console.print(f"  [cyan]{key}:[/cyan] {value}")
        
        # Log to wandb if enabled
        if self.wandb_enabled and WANDB_AVAILABLE and step is not None:
            try:
                wandb.log({f"tpu/{k}": v for k, v in metrics.items() 
                         if k != 'timestamp' and isinstance(v, (int, float))}, 
                         step=step)
            except Exception as e:
                logger.error(f"Failed to log metrics to W&B: {e}")
        
        return True
    
    def save_metrics(self, filename=None):
        """Save collected metrics to file"""
        if not self.metrics_history:
            logger.warning("No metrics to save")
            return None
            
        if not filename:
            filename = f"tpu_metrics_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        
        filepath = os.path.join(self.log_dir, filename)
        
        try:
            import json
            with open(filepath, 'w') as f:
                json.dump(self.metrics_history, f, indent=2)
            
            logger.info(f"Saved TPU metrics to {filepath}")
            return filepath
        except Exception as e:
            logger.error(f"Failed to save metrics to file: {e}")
            return None

# Training progress tracking with rich
def create_progress_bar(total, description="Training"):
    """Create a rich progress bar for training"""
    return Progress(
        TextColumn("[bold blue]{task.description}"),
        BarColumn(),
        TextColumn("[bold]{task.completed}/{task.total}"),
        TimeElapsedColumn(),
        TextColumn("[bold green]{task.speed:.2f} it/s"),
        console=console
    ) 