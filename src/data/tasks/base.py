"""
Base classes and interfaces for task generators.

This module defines the base TaskGenerator class and factory for creating
task-specific generators.
"""

import logging
from abc import ABC, abstractmethod
from typing import Dict, List, Optional, Any

# Configure logger
logger = logging.getLogger('tasks.base')

class TaskGenerator(ABC):
    """Abstract base class for all task generators."""
    
    def __init__(self, config: Dict):
        """
        Initialize the task generator with configuration.
        
        Args:
            config: Configuration dictionary
        """
        self.config = config
        self.task_name = self.__class__.__name__.replace('Generator', '')
    
    @abstractmethod
    def generate_labels(self, inputs: List[Any], tokenizer: Any = None) -> List[Any]:
        """
        Generate task-specific labels for inputs.
        
        Args:
            inputs: List of input examples
            tokenizer: Optional tokenizer for text processing
            
        Returns:
            List of task-specific labels
        """
        pass
    
    @abstractmethod
    def supports_model_type(self, model_type: str) -> bool:
        """
        Check if this generator supports the given model type.
        
        Args:
            model_type: Model type ('transformer' or 'static')
            
        Returns:
            True if supported, False otherwise
        """
        pass
        
    def log_info(self, message: str) -> None:
        """Log information with task name prefix."""
        logger.info(f"[{self.task_name}] {message}")
        
    def log_warning(self, message: str) -> None:
        """Log warning with task name prefix."""
        logger.warning(f"[{self.task_name}] {message}")
        
    def log_error(self, message: str) -> None:
        """Log error with task name prefix."""
        logger.error(f"[{self.task_name}] {message}")

class TaskGeneratorFactory:
    """Factory for creating task-specific generators."""
    
    @staticmethod
    def create(task_name: str, config: Dict) -> Optional[TaskGenerator]:
        """Create a task-specific generator based on task type."""
        from .masking import MLMGenerator, LMLMGenerator
        from .sequence import NERGenerator, POSGenerator
        from .sentence import NSPGenerator, DiscourseGenerator
        from .classification import SentimentGenerator
        from .contrastive import ContrastiveGenerator
        
        task_map = {
            'mlm': MLMGenerator,
            'lmlm': LMLMGenerator,
            'nsp': NSPGenerator,
            'ner': NERGenerator,
            'pos': POSGenerator,
            'discourse': DiscourseGenerator,
            'sentiment': SentimentGenerator,
            'contrastive': ContrastiveGenerator
        }
        
        task_name = task_name.lower()
        if task_name in task_map:
            return task_map[task_name](config)
        else:
            logger.warning(f"Unknown task type: {task_name}")
            return None 