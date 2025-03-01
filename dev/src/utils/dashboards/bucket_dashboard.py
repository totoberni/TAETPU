import os
import time
import tensorflow as tf
from .super_dashboard import Dashboard
from ..logging.cls_logging import log, log_success, log_warning, log_error, ensure_directory
from ..logging.config_loader import get_config

class BucketDashboard(Dashboard):
    """Dashboard for visualizing GCS bucket transfer metrics using TensorBoard"""
    
    def __init__(self, tb_log_dir=None, use_gcs=None, config_path=None):
        """Initialize the GCS bucket dashboard
        
        Args:
            tb_log_dir: Directory for TensorBoard logs (if None, use config)
            use_gcs: Whether to use GCS bucket for storage (if None, use config)
            config_path: Path to configuration file (if None, use default)
        """
        # Initialize base dashboard with bucket-specific name
        super().__init__(name="bucket", tb_log_dir=tb_log_dir, use_gcs=use_gcs, config_path=config_path)
        
        # Define categories for specialized writers
        categories = {
            "transfer": os.path.join(self.tb_log_dir, "transfer_rates"),
            "network": os.path.join(self.tb_log_dir, "network_traffic")
        }
        
        # Create specialized writers using base class method
        self.create_specialized_writers(categories)
        
        # Define category keywords for metric categorization
        self.category_keywords = {
            "transfer": ['transfer', 'rate', 'mbps', 'throughput'],
            "network": ['network', 'rx', 'tx', 'bytes']
        }
        
        log_success("BucketDashboard initialized with TensorBoard integration")
        
    def update_dashboard(self, metrics, step):
        """Update the dashboard with GCS metrics
        
        Args:
            metrics: Dictionary of metrics to update
            step: Step value for the metrics (e.g., timestamp)
        """
        # First, update using the parent implementation for all metrics
        super().update_dashboard(metrics, step)
        
        # Categorize metrics based on keywords
        categorized_metrics = self.categorize_metrics(metrics, self.category_keywords)
        
        # Update specialized writers using the base class method
        self.update_specialized_writers(categorized_metrics, step)
    
    def run(self, update_interval=60):
        """Run the dashboard with periodic updates
        
        Args:
            update_interval: Interval in seconds between updates
        """
        if not self.enabled:
            log_warning("BucketDashboard is disabled. Not starting.")
            return
            
        log_success(f"BucketDashboard running with update interval: {update_interval}s")
        
        try:
            while True:
                # This would typically collect metrics directly,
                # but in our refactored design, metrics come from monitors
                time.sleep(update_interval)
        except KeyboardInterrupt:
            log("BucketDashboard stopped by user")