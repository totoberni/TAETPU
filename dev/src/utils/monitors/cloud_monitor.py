#!/usr/bin/env python3
"""
Centralized Google Cloud Monitoring functionality.
"""
import time
from datetime import datetime, timedelta
from ..logging.cls_logging import log, log_success, log_warning, log_error

# Try to import Google Cloud Monitoring
try:
    from google.cloud import monitoring_v3
    from google.protobuf import timestamp_pb2
    CLOUD_MONITORING_AVAILABLE = True
except ImportError:
    CLOUD_MONITORING_AVAILABLE = False
    log_warning("Google Cloud Monitoring libraries not available; some features will be disabled.")

class CloudMonitoringClient:
    """Wrapper for Google Cloud Monitoring client with common functionality."""
    
    def __init__(self, project_id=None):
        """Initialize Cloud Monitoring client.
        
        Args:
            project_id: Google Cloud project ID (if None, attempt to auto-detect)
        """
        self.available = CLOUD_MONITORING_AVAILABLE
        self.client = None
        self.project_name = None
        
        if not self.available:
            log_warning("Cloud Monitoring is not available (missing dependencies)")
            return
            
        try:
            # Initialize the client
            self.client = monitoring_v3.MetricServiceClient()
            
            # Set up project name
            if project_id:
                self.project_name = f"projects/{project_id}"
                log_success(f"Cloud Monitoring initialized for project: {project_id}")
            else:
                log_warning("No project ID provided for Cloud Monitoring, some features may be limited")
        except Exception as e:
            log_error(f"Failed to initialize Cloud Monitoring client: {e}")
            self.client = None
    
    def is_available(self):
        """Check if Cloud Monitoring is available.
        
        Returns:
            bool: True if available, False otherwise
        """
        return self.available and self.client is not None
    
    def get_metric_data(self, metric_type, resource_type, lookback_minutes=5, alignment_period_seconds=60):
        """Get metric data from Cloud Monitoring.
        
        Args:
            metric_type: Metric type (e.g., 'compute.googleapis.com/instance/cpu/utilization')
            resource_type: Resource type (e.g., 'gce_instance')
            lookback_minutes: Number of minutes to look back
            alignment_period_seconds: Alignment period in seconds
            
        Returns:
            dict: Dictionary of metric data, or None if error
        """
        if not self.is_available() or not self.project_name:
            return None
            
        try:
            # Calculate time range
            now = datetime.utcnow()
            seconds = int(time.time())
            nanos = int((time.time() - seconds) * 10**9)
            end_time = timestamp_pb2.Timestamp(seconds=seconds, nanos=nanos)
            
            start_time = timestamp_pb2.Timestamp()
            start_time.FromDatetime(now - timedelta(minutes=lookback_minutes))
            
            # Create interval
            interval = monitoring_v3.TimeInterval(
                start_time=start_time,
                end_time=end_time
            )
            
            # Create aggregation
            aggregation = monitoring_v3.Aggregation(
                alignment_period=timedelta(seconds=alignment_period_seconds),
                per_series_aligner=monitoring_v3.Aggregation.Aligner.ALIGN_MEAN
            )
            
            # Build request
            request = monitoring_v3.ListTimeSeriesRequest(
                name=self.project_name,
                filter=f'metric.type="{metric_type}" AND resource.type="{resource_type}"',
                interval=interval,
                aggregation=aggregation
            )
            
            # Get response
            response = self.client.list_time_series(request)
            
            # Process response
            result = {}
            for time_series in response:
                metric_labels = dict(time_series.metric.labels)
                resource_labels = dict(time_series.resource.labels)
                
                # Create a key for this time series
                key_parts = []
                for label_key, label_value in sorted(metric_labels.items()):
                    key_parts.append(f"{label_key}:{label_value}")
                for label_key, label_value in sorted(resource_labels.items()):
                    key_parts.append(f"{label_key}:{label_value}")
                    
                key = "/".join(key_parts) or "default"
                
                # Extract values
                values = []
                for point in time_series.points:
                    timestamp = point.interval.end_time.seconds
                    value = getattr(point.value, point.value.WhichOneof("value"))
                    values.append((timestamp, value))
                
                result[key] = values
                
            return result
            
        except Exception as e:
            log_error(f"Error getting metric data: {e}")
            return None 