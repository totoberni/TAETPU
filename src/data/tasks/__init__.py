"""
Task generators for transformer and static embedding models.

This package provides generators for various NLP tasks with a focus on
TPU optimization and compatibility.
"""

from .base import TaskGenerator, TaskGeneratorFactory

def create_task_generator(task_name, config):
    """
    Create a task-specific generator based on task name.
    
    Args:
        task_name: Name of the task
        config: Configuration dictionary
        
    Returns:
        Task generator instance or None if task is not supported
    """
    return TaskGeneratorFactory.create(task_name, config) 