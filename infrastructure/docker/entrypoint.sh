#!/bin/bash
set -e

# Log the message
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Create the required directory structure inside the volumes
create_directory_structure() {
  log "Creating required directory structure inside volumes..."
  
  # Define required directories
  REQUIRED_DIRS=(
    "/app/mount/src/datasets/raw"
    "/app/mount/src/datasets/clean/transformer"
    "/app/mount/src/datasets/clean/static"
    "/app/mount/src/cache/prep"
    "/app/mount/src/models/prep"
    "/app/mount/src/configs"
  )
  
  # Create directories
  for dir in "${REQUIRED_DIRS[@]}"; do
    mkdir -p "$dir"
    log "Created directory: $dir"
  done
  
  # Set proper permissions
  chmod -R 777 /app/mount/src
  
  log "Directory structure setup complete"
}

# Main entrypoint
main() {
  log "Container starting..."
  
  # Create the required directory structure
  create_directory_structure
  
  # Execute the command passed to docker run
  log "Executing command: $@"
  exec "$@"
}

# Call main function with all arguments passed to the script
main "$@" 