import os
import torch
import torch.nn as nn
import torch_xla.core.xla_model as xm
import torch_xla.distributed.parallel_loader as pl
from torch.utils.data import TensorDataset, DataLoader

# Import our monitoring utilities
from utils.tpu_logging import setup_logger, create_progress_bar, TPUMetricsLogger
from utils.profiling import ModelProfiler, profile_function
from utils.experiment import ExperimentTracker

# Set up logger
logger = setup_logger(log_level="INFO", log_file="logs/transformer_ablation.log")

# Define a simple model for demonstration
class SimpleTransformer(nn.Module):
    def __init__(self, d_model=512, nhead=8, dim_feedforward=2048):
        super().__init__()
        self.encoder_layer = nn.TransformerEncoderLayer(
            d_model=d_model, 
            nhead=nhead,
            dim_feedforward=dim_feedforward
        )
        self.transformer = nn.TransformerEncoder(self.encoder_layer, num_layers=6)
        self.linear = nn.Linear(d_model, d_model)
        
    def forward(self, x):
        return self.linear(self.transformer(x))

@profile_function
def train_one_epoch(model, dataloader, optimizer, criterion, device):
    """Train model for one epoch with profiling"""
    model.train()
    total_loss = 0
    
    # Create progress bar
    progress = create_progress_bar(len(dataloader), description="Training")
    task_id = progress.add_task("Training", total=len(dataloader))
    
    with progress:
        for batch_idx, (data, target) in enumerate(dataloader):
            optimizer.zero_grad()
            
            # Forward pass
            output = model(data)
            loss = criterion(output, target)
            
            # Backward pass
            loss.backward()
            
            # Optimizer step with XLA
            xm.optimizer_step(optimizer)
            xm.mark_step()
            
            # Update metrics
            total_loss += loss.item()
            progress.update(task_id, advance=1, 
                           description=f"Training [Loss: {loss.item():.4f}]")
            
    return total_loss / len(dataloader)

def main():
    # Create dummy data
    logger.info("Creating dummy data for testing")
    batch_size = 32
    seq_len = 128
    d_model = 512
    
    # Random input data
    x = torch.randn(batch_size, seq_len, d_model)
    y = torch.randn(batch_size, seq_len, d_model)
    
    # Create dataset and dataloader
    dataset = TensorDataset(x, y)
    dataloader = DataLoader(dataset, batch_size=8)
    
    # Initialize experiment tracker
    config = {
        "d_model": d_model,
        "nhead": 8,
        "dim_feedforward": 2048,
        "batch_size": batch_size,
        "seq_len": seq_len,
    }
    
    experiment = ExperimentTracker(
        experiment_name="transformer_ablation_test",
        config=config,
        use_tensorboard=True,
        use_wandb=False,  # Set to True to enable W&B
    )
    
    # Initialize model
    logger.info("Initializing model")
    device = xm.xla_device()
    model = SimpleTransformer(d_model=d_model).to(device)
    
    # Set up optimizer and loss
    optimizer = torch.optim.Adam(model.parameters(), lr=0.001)
    criterion = nn.MSELoss()
    
    # Log the model architecture
    experiment.log_model(model, name="transformer")
    
    # Initialize profiler
    profiler = ModelProfiler(model, log_dir="logs/profiler")
    
    # Initialize TPU metrics logger
    tpu_logger = TPUMetricsLogger(log_dir="logs/tpu_metrics")
    
    # Start profiling
    profiler.start_profiling("training_run")
    
    # Train for a few epochs
    num_epochs = 3
    for epoch in range(num_epochs):
        logger.info(f"Starting epoch {epoch+1}/{num_epochs}")
        
        # Report memory usage before training
        profiler.profile_memory(prefix=f"Epoch {epoch+1} start")
        
        # Train one epoch
        with profiler.profile_step(f"epoch_{epoch+1}"):
            train_loss = train_one_epoch(
                model, dataloader, optimizer, criterion, device
            )
        
        # Log metrics
        metrics = {
            "train/loss": train_loss,
            "train/epoch": epoch + 1,
        }
        experiment.log_metrics(metrics, step=epoch+1)
        
        # Log parameter histograms
        experiment.log_parameters(
            {name: param.data for name, param in model.named_parameters()}, 
            step=epoch+1
        )
        
        # Log TPU metrics
        tpu_logger.log_metrics(step=epoch+1)
        
        # Log memory usage after epoch
        profiler.profile_memory(prefix=f"Epoch {epoch+1} end")
        
        # Save checkpoint
        if (epoch + 1) % 1 == 0:
            experiment.save_checkpoint(
                model.state_dict(), 
                filename=f"checkpoint_epoch_{epoch+1}.pt"
            )
    
    # Stop profiling
    profiler.stop_profiling()
    
    # Save final TPU metrics
    tpu_logger.save_metrics()
    
    # Finish the experiment
    experiment.finish()
    
    logger.info("Training completed successfully")

if __name__ == "__main__":
    main() 