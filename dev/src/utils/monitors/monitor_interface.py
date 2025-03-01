#!/usr/bin/env python3
"""
Abstract base classes defining interfaces for monitoring components.
"""
from abc import ABC, abstractmethod
import threading

class MonitorInterface(ABC):
    """Abstract base class defining the Monitor interface."""
    
    @abstractmethod
    def start(self):
        """Start monitoring."""
        pass
    
    @abstractmethod
    def stop(self):
        """Stop monitoring."""
        pass
    
    @abstractmethod
    def get_metrics(self):
        """Get current metrics.
        
        Returns:
            dict: Dictionary of metrics
        """
        pass
    
    @abstractmethod
    def record_metrics(self, metrics=None, step=None):
        """Record metrics to TensorBoard or other destination.
        
        Args:
            metrics: Dictionary of metrics to record (if None, collect and record current metrics)
            step: Step/timestamp to associate with metrics
        """
        pass
    
    @abstractmethod
    def __enter__(self):
        """Context manager entry.
        
        Returns:
            self: Returns self for use in context manager
        """
        pass
    
    @abstractmethod
    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit."""
        pass


class MetricsPublisher(ABC):
    """Abstract base class for components that publish metrics."""
    
    def __init__(self):
        """Initialize the metrics publisher."""
        self._subscribers = []
        self._lock = threading.Lock()
    
    def add_subscriber(self, subscriber):
        """Add a subscriber to receive metrics updates.
        
        Args:
            subscriber: Callback function to receive metrics updates
            
        Returns:
            int: Subscriber ID
        """
        with self._lock:
            subscriber_id = len(self._subscribers)
            self._subscribers.append(subscriber)
            return subscriber_id
    
    def remove_subscriber(self, subscriber_id):
        """Remove a subscriber.
        
        Args:
            subscriber_id: ID of subscriber to remove
            
        Returns:
            bool: True if removal was successful, False otherwise
        """
        with self._lock:
            if 0 <= subscriber_id < len(self._subscribers):
                self._subscribers[subscriber_id] = None
                return True
            return False
    
    def publish_metrics(self, metrics, timestamp=None):
        """Publish metrics to all subscribers.
        
        Args:
            metrics: Dictionary of metrics to publish
            timestamp: Timestamp associated with metrics
        """
        with self._lock:
            for subscriber in self._subscribers:
                if subscriber is not None:
                    try:
                        subscriber(metrics, timestamp)
                    except Exception as e:
                        # Log error but continue with other subscribers
                        print(f"Error in subscriber: {e}") 