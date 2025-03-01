"""
Logging infrastructure for TPU monitoring and cloud systems integration.
Provides consistent logging across shell scripts and Python code.
"""
import os
import sys
import subprocess
from datetime import datetime
from rich.console import Console
from rich.progress import Progress, TextColumn, BarColumn, TimeElapsedColumn
from loguru import logger

# Create rich console for formatted output
console = Console()

def setup_logger(log_level="INFO", log_file=None):
    """Configure Loguru logger with console and optional file outputs"""
    # Remove default handler
    logger.remove()
    
    # Add console handler with custom format
    logger.add(
        sys.stderr,
        format="<green>[{time:YYYY-MM-DD HH:mm:ss}]</green> <level>{message}</level>",
        level=log_level,
        colorize=True
    )
    
    # Add custom log levels
    logger.level("SUCCESS", no=25, color="<green>")
    
    # Add file handler if log_file is provided
    if log_file:
        ensure_directory(os.path.dirname(log_file))
        logger.add(
            log_file,
            format="[{time:YYYY-MM-DD HH:mm:ss}] [{level}] {message}",
            level=log_level,
            rotation="10 MB",
            compression="zip"
        )

def create_progress_bar(description="Processing", total=100):
    """Create a rich progress bar for tracking long-running operations
    
    Args:
        description: Text description of the operation
        total: Total number of steps
        
    Returns:
        Progress: A rich progress bar instance
    """
    return Progress(
        TextColumn("[bold blue]{task.description}"),
        BarColumn(),
        TextColumn("[bold]{task.percentage:>3.0f}%"),
        TextColumn("•"),
        TimeElapsedColumn()
    )

def ensure_directory(directory):
    """Ensure a directory exists, creating it if necessary
    
    Args:
        directory: Path to directory
        
    Returns:
        bool: True if directory exists or was created
    """
    if not directory:
        return False
        
    try:
        os.makedirs(directory, exist_ok=True)
        return True
    except Exception as e:
        logger.error(f"Failed to create directory {directory}: {e}")
        return False

def ensure_directories(directories):
    """Ensure multiple directories exist
    
    Args:
        directories: List of directory paths
        
    Returns:
        bool: True if all directories exist or were created
    """
    if not directories:
        return False
        
    success = True
    for directory in directories:
        if not ensure_directory(directory):
            success = False
    return success

def log(message):
    """Log an informational message
    
    Args:
        message: Message to log
    """
    logger.info(message)

def log_success(message):
    """Log a success message
    
    Args:
        message: Message to log
    """
    logger.log("SUCCESS", message)

def log_warning(message):
    """Log a warning message
    
    Args:
        message: Message to log
    """
    logger.warning(message)

def log_error(message):
    """Log an error message
    
    Args:
        message: Message to log
    """
    logger.error(message)

def run_shell_command(cmd, shell=False, timeout=None, capture_output=True):
    """Run a shell command and return the result
    
    Args:
        cmd: Command to run (string or list)
        shell: Whether to use shell to run the command
        timeout: Timeout in seconds
        capture_output: Whether to capture stdout/stderr
        
    Returns:
        tuple: (success, output) where success is a boolean and output is stdout or stderr
    """
    try:
        if capture_output:
            result = subprocess.run(
                cmd,
                shell=shell,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                timeout=timeout
            )
            
            if result.returncode == 0:
                return True, result.stdout
            else:
                return False, result.stderr
        else:
            result = subprocess.run(
                cmd,
                shell=shell,
                timeout=timeout
            )
            return result.returncode == 0, None
    except subprocess.TimeoutExpired:
        return False, f"Command timed out after {timeout} seconds"
    except Exception as e:
        return False, str(e) 