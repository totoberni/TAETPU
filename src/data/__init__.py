"""
Transformer Ablation Experiment Data Processing Package.

This package provides tools for preprocessing data for transformer ablation experiments
with TPU optimization.
"""

from .pipeline import main as pipeline_main

# Create command-line entrypoints that maintain compatibility
if __name__ == "__main__":
    pipeline_main() 