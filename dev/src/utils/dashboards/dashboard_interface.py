#!/usr/bin/env python3
"""
Abstract base classes defining interfaces for dashboard components.
"""
from abc import ABC, abstractmethod

class DashboardInterface(ABC):
    """Abstract base class defining the Dashboard interface."""
    
    @abstractmethod
    def update_dashboard(self, metrics, step=None):
        """Update the dashboard with new metrics.
        
        Args:
            metrics: Dictionary of metrics to update
            step: Step value for the metrics (e.g., timestamp)
        """
        pass
    
    @abstractmethod
    def start(self, port=None, host=None):
        """Start the dashboard server.
        
        Args:
            port: Port to bind the server to
            host: Host to bind the server to
            
        Returns:
            bool: True if successful, False otherwise
        """
        pass
    
    @abstractmethod
    def stop(self):
        """Stop the dashboard server.
        
        Returns:
            bool: True if successful, False otherwise
        """
        pass
    
    @abstractmethod
    def get_url(self):
        """Get the URL to access the dashboard.
        
        Returns:
            str: URL to access the dashboard
        """
        pass
    
    @abstractmethod
    def __enter__(self):
        """Context manager entry.
        
        Returns:
            self: Returns self for use in context manager
        """
        return self
    
    @abstractmethod
    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit."""
        self.stop()


class MetricsSubscriber:
    """Base class for components that subscribe to metrics."""
    
    def __init__(self):
        """Initialize the metrics subscriber."""
        self._publishers = []
        self._subscriber_ids = {}
    
    def subscribe_to(self, publisher):
        """Subscribe to a metrics publisher.
        
        Args:
            publisher: MetricsPublisher to subscribe to
            
        Returns:
            bool: True if subscription was successful, False otherwise
        """
        try:
            subscriber_id = publisher.add_subscriber(self.update_dashboard)
            self._publishers.append(publisher)
            self._subscriber_ids[id(publisher)] = subscriber_id
            return True
        except Exception as e:
            print(f"Error subscribing to publisher: {e}")
            return False
    
    def unsubscribe_from(self, publisher):
        """Unsubscribe from a metrics publisher.
        
        Args:
            publisher: MetricsPublisher to unsubscribe from
            
        Returns:
            bool: True if unsubscription was successful, False otherwise
        """
        publisher_id = id(publisher)
        if publisher_id in self._subscriber_ids:
            subscriber_id = self._subscriber_ids[publisher_id]
            success = publisher.remove_subscriber(subscriber_id)
            if success:
                del self._subscriber_ids[publisher_id]
                self._publishers.remove(publisher)
            return success
        return False
    
    def unsubscribe_all(self):
        """Unsubscribe from all publishers."""
        for publisher in list(self._publishers):
            self.unsubscribe_from(publisher) 