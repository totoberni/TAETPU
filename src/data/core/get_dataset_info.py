#!/usr/bin/env python3
"""
get_dataset_info.py - Command-line utility to retrieve dataset information from config.

This script provides a command-line interface to the config_loader module,
allowing shell scripts to easily retrieve dataset information.
"""
import argparse
import sys
import json
import config_loader

def main():
    parser = argparse.ArgumentParser(description="Get dataset information from config")
    parser.add_argument("--config-path", type=str, default=None,
                        help="Path to the data configuration YAML file")
    
    # Add subcommands
    subparsers = parser.add_subparsers(dest="command", help="Command to execute")
    
    # Get all dataset keys
    subparsers.add_parser("get-keys", help="Get all dataset keys")
    
    # Get info for a specific dataset
    info_parser = subparsers.add_parser("get-info", help="Get info for a specific dataset")
    info_parser.add_argument("dataset_key", help="Dataset key to get info for")
    
    # Get name for a specific dataset
    name_parser = subparsers.add_parser("get-name", help="Get name for a specific dataset")
    name_parser.add_argument("dataset_key", help="Dataset key to get name for")
    
    # Check if a dataset exists
    exists_parser = subparsers.add_parser("exists", help="Check if a dataset exists")
    exists_parser.add_argument("dataset_key", help="Dataset key to check")
    
    # Format option
    parser.add_argument("--format", choices=["text", "json"], default="text",
                        help="Output format (default: text)")
    
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        return 1
    
    # Execute the command
    if args.command == "get-keys":
        keys = config_loader.get_dataset_keys(args.config_path)
        if args.format == "json":
            print(json.dumps(keys))
        else:
            print(" ".join(keys))
    
    elif args.command == "get-info":
        info = config_loader.get_dataset_info(args.dataset_key, args.config_path)
        if info is None:
            print(f"Dataset '{args.dataset_key}' not found", file=sys.stderr)
            return 1
        
        if args.format == "json":
            print(json.dumps(info))
        else:
            for key, value in info.items():
                print(f"{key}: {value}")
    
    elif args.command == "get-name":
        name = config_loader.get_dataset_name(args.dataset_key, args.config_path)
        if name is None:
            print(f"Dataset '{args.dataset_key}' not found or has no name", file=sys.stderr)
            return 1
        
        print(name)
    
    elif args.command == "exists":
        exists = args.dataset_key in config_loader.get_dataset_keys(args.config_path)
        if args.format == "json":
            print(json.dumps(exists))
        else:
            print("yes" if exists else "no")
        
        return 0 if exists else 1
    
    return 0

if __name__ == "__main__":
    sys.exit(main()) 