import os
import json
import torch
import wandb
from datetime import datetime
from loguru import logger
from torch.utils.tensorboard import SummaryWriter
import torch_xla.core.xla_model as xm

class ExperimentTracker:
    """Track experiments with multiple backends (TensorBoard, W&B)"""
    
    def __init__(self, experiment_name, config=None, log_dir="logs", 
                 use_tensorboard=True, use_wandb=False, wandb_project=None,
                 wandb_entity=None, tpu_metrics=True):
        
        self.experiment_name = experiment_name
        self.start_time = datetime.now()
        self.config = config or {}
        self.experiment_id = f"{experiment_name}_{self.start_time.strftime('%Y%m%d_%H%M%S')}"
        self.log_dir = os.path.join(log_dir, self.experiment_id)
        os.makedirs(self.log_dir, exist_ok=True)
        
        # Save config
        with open(os.path.join(self.log_dir, 'config.json'), 'w') as f:
            json.dump(self.config, f, indent=2)
        
        # Setup backends
        self.tb_writer = None
        if use_tensorboard:
            self.tb_writer = SummaryWriter(log_dir=os.path.join(self.log_dir, 'tensorboard'))
        
        self.wandb_run = None
        if use_wandb:
            self.wandb_run = wandb.init(
                project=wandb_project or "tpu-transformer-ablation",
                entity=wandb_entity,
                name=self.experiment_id,
                config=self.config,
                dir=self.log_dir
            )
        
        # Save tpu metrics
        self.tpu_metrics = tpu_metrics
        self.metrics_history = []
        
        logger.info(f"Experiment tracker initialized: {self.experiment_id}")
        logger.info(f"Logs will be saved to: {self.log_dir}")
    
    def log_metrics(self, metrics, step=None, commit=True):
        """Log metrics to all configured backends"""
        
        # Add TPU metrics if enabled
        if self.tpu_metrics:
            try:
                import torch_xla.debug.metrics as met
                tpu_metrics = met.metrics_report()
                # Filter numerical values and prefix with tpu/
                tpu_dict = {f"tpu/{k}": v for k, v in tpu_metrics.items() 
                           if isinstance(v, (int, float))}
                metrics.update(tpu_dict)
            except Exception as e:
                logger.warning(f"Failed to collect TPU metrics: {e}")
        
        # Save to history
        metrics_with_step = metrics.copy()
        metrics_with_step["step"] = step
        metrics_with_step["timestamp"] = datetime.now().isoformat()
        self.metrics_history.append(metrics_with_step)
        
        # Log to TensorBoard
        if self.tb_writer:
            for name, value in metrics.items():
                if isinstance(value, (int, float)):
                    self.tb_writer.add_scalar(name, value, step)
                elif isinstance(value, torch.Tensor) and value.numel() == 1:
                    self.tb_writer.add_scalar(name, value.item(), step)
        
        # Log to Weights & Biases
        if self.wandb_run:
            wandb.log(metrics, step=step, commit=commit)
    
    def log_model(self, model, name="model", step=None):
        """Log model architecture and weights"""
        if self.wandb_run:
            wandb.watch(model, log="all", log_freq=100)
        
        # Log architecture as text
        if self.tb_writer:
            self.tb_writer.add_text(f"{name}/architecture", str(model), step)
    
    def log_parameters(self, parameters, step=None):
        """Log model parameters"""
        if self.tb_writer:
            for name, param in parameters.items():
                self.tb_writer.add_histogram(name, param, step)
        
        if self.wandb_run:
            wandb.log({f"param/{name}": wandb.Histogram(param.detach().cpu().numpy())
                     for name, param in parameters.items()}, step=step)
    
    def log_gradients(self, named_parameters, step=None):
        """Log gradients of model parameters"""
        if not self.tb_writer and not self.wandb_run:
            return
        
        for name, param in named_parameters:
            if param.grad is not None:
                # TensorBoard
                if self.tb_writer:
                    self.tb_writer.add_histogram(f"grad/{name}", param.grad, step)
                
                # Weights & Biases
                if self.wandb_run:
                    wandb.log({f"grad/{name}": wandb.Histogram(param.grad.detach().cpu().numpy())}, 
                             step=step)
    
    def log_figure(self, figure, name, step=None):
        """Log matplotlib figure"""
        if self.tb_writer:
            self.tb_writer.add_figure(name, figure, step)
        
        if self.wandb_run:
            wandb.log({name: wandb.Image(figure)}, step=step)
    
    def save_checkpoint(self, state_dict, filename=None):
        """Save model checkpoint"""
        if filename is None:
            filename = f"checkpoint_{datetime.now().strftime('%Y%m%d_%H%M%S')}.pt"
        
        checkpoint_path = os.path.join(self.log_dir, filename)
        xm.save(state_dict, checkpoint_path)
        logger.info(f"Checkpoint saved to {checkpoint_path}")
        
        if self.wandb_run:
            artifact = wandb.Artifact(name=f"checkpoint-{self.experiment_id}", 
                                     type="model")
            artifact.add_file(checkpoint_path)
            self.wandb_run.log_artifact(artifact)
    
    def finish(self):
        """Clean up and finalize the experiment"""
        # Save metrics history
        with open(os.path.join(self.log_dir, 'metrics_history.json'), 'w') as f:
            json.dump(self.metrics_history, f, indent=2)
        
        # Close TensorBoard writer
        if self.tb_writer:
            self.tb_writer.close()
        
        # Finish W&B run
        if self.wandb_run:
            wandb.finish()
        
        end_time = datetime.now()
        duration = end_time - self.start_time
        logger.info(f"Experiment {self.experiment_id} completed in {duration}")
        logger.info(f"Results saved to {self.log_dir}") 