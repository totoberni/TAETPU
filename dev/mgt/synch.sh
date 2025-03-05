#!/bin/bash

# --- DETERMINE SCRIPT AND PROJECT DIRECTORIES ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_DIR/dev/src"

# --- IMPORT COMMON FUNCTIONS ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

# --- MAIN SCRIPT ---
init_script 'TPU File Synchronization'

show_usage() {
  echo "Usage: $0 [--restart] [--watch] [--utils] [--specific file1.py file2.py]"
  echo ""
  echo "Synchronize Python files from dev/src to the TPU VM with continuous watching."
  echo ""
  echo "Options:"
  echo "  --restart          Restart the Docker container after syncing"
  echo "  --watch            Watch for changes and sync automatically"
  echo "  --utils            Include utils directory in synchronization"
  echo "  --specific         Only sync specific files provided as additional arguments"
  echo "  --compose-watch    Use Docker Compose watch instead of rsync/scp (if available)"
  echo "  -h, --help         Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0                        # Sync all Python files once"
  echo "  $0 --restart              # Sync and restart container"
  echo "  $0 --watch                # Sync continuously when files change"
  echo "  $0 --specific model.py    # Sync only model.py"
  echo "  $0 --utils --watch        # Sync utils directory and watch for changes"
  echo "  $0 --compose-watch        # Use Docker Compose watch for development"
  echo ""
  echo "Note: This script can be run from any directory in the codebase"
  exit 1
}

# Function to create docker-compose.yml for watch mode
create_compose_file() {
  local compose_file="$PROJECT_DIR/docker-compose.yml"
  
  log "Creating Docker Compose file for watch mode at $compose_file"
  
  # Create or overwrite the docker-compose.yml file
  cat > "$compose_file" << EOF
version: '3.8'

services:
  tpu-dev:
    image: gcr.io/$PROJECT_ID/tpu-hello-world:v1
    privileged: true
    devices:
      - /dev/accel0:/dev/accel0
    environment:
      - PJRT_DEVICE=TPU
      - XLA_USE_BF16=1
      - PYTHONUNBUFFERED=1
    volumes:
      - /tmp/dev/src:/app/dev/src
    working_dir: /app
    command: /bin/bash -c "echo 'Container started in watch mode. Ready for development.' && sleep infinity"
    
    # Watch configuration for auto-updating on file changes
    develop:
      watch:
        - action: sync
          path: ./dev/src
          target: /app/dev/src
          ignore:
            - "__pycache__/"
            - "*.pyc"
            - "*.pyo"
            - "*.pyd"
            - ".pytest_cache/"
        - action: sync+restart
          path: ./dev/src/requirements.txt
          target: /app/requirements.txt
EOF
  
  log_success "Docker Compose file created successfully"
}

# Function to sync files to TPU VM
sync_files() {
  local specific_files=("$@")
  
  log "Syncing files to TPU VM..."
  
  # Create the target directory
  ssh_with_timeout "mkdir -p /tmp/dev/src" 10
  
  # Handle specific files vs all files
  if [ ${#specific_files[@]} -gt 0 ]; then
    for file in "${specific_files[@]}"; do
      if [ -f "$SRC_DIR/$file" ]; then
        log "- Syncing $file"
        gcloud compute tpus tpu-vm scp "$SRC_DIR/$file" "$TPU_NAME":/tmp/dev/src/ \
            --zone="$TPU_ZONE" \
            --project="$PROJECT_ID" \
            --worker=all
      else
        log_warning "File $file not found in $SRC_DIR - skipping"
      fi
    done
  else
    # Copy all Python files
    for file in "$SRC_DIR"/*.py; do
      if [ -f "$file" ]; then
        base_file=$(basename "$file")
        log "- Syncing $base_file"
        gcloud compute tpus tpu-vm scp "$file" "$TPU_NAME":/tmp/dev/src/ \
            --zone="$TPU_ZONE" \
            --project="$PROJECT_ID" \
            --worker=all
      fi
    done
  fi
  
  log_success "File synchronization completed successfully"
}

# Function to sync utils directory
sync_utils() {
  if [[ -d "$SRC_DIR/utils" ]]; then
    log "Syncing utils directory..."
    
    # Create the utils directory on the TPU VM
    ssh_with_timeout "mkdir -p /tmp/dev/src/utils" 10
    
    # Create a temporary directory for the utils files
    TEMP_DIR=$(mktemp -d)
    cp -r "$SRC_DIR/utils/"* "$TEMP_DIR/" 2>/dev/null || true
    
    # Use recursive copy for the utils directory
    gcloud compute tpus tpu-vm scp --recurse "$TEMP_DIR/"* "$TPU_NAME":/tmp/dev/src/utils/ \
      --zone="$TPU_ZONE" \
      --project="$PROJECT_ID" \
      --worker=all
    
    # Clean up temporary directory
    rm -rf "$TEMP_DIR"
    
    log_success "Utils directory synchronized successfully"
  else
    log_warning "Utils directory doesn't exist in $SRC_DIR"
  fi
}

# Function to restart Docker container
restart_container() {
  log "Restarting Docker container on TPU VM..."
  
  # Create a temporary script to run on the TPU VM
  TEMP_SCRIPT=$(mktemp)
  cat > "$TEMP_SCRIPT" << EOF
#!/bin/bash
echo "Looking for running Docker containers..."
CONTAINERS=\$(docker ps -q --filter ancestor=gcr.io/$PROJECT_ID/tpu-hello-world:v1 2>/dev/null)

if [ -z "\$CONTAINERS" ]; then
  echo "No running containers found to restart."
  echo "Starting a new container..."
  
  # Run a new container in the background with the mounted directory
  docker run -d --rm --privileged \\
    --device=/dev/accel0 \\
    -e PJRT_DEVICE=TPU \\
    -e XLA_USE_BF16=1 \\
    -e PYTHONUNBUFFERED=1 \\
    -v /tmp/dev/src:/app/dev/src \\
    -w /app \\
    gcr.io/$PROJECT_ID/tpu-hello-world:v1 \\
    /bin/bash -c "echo 'Container started, waiting for commands.' && sleep infinity"
    
  if [ \$? -ne 0 ]; then
    echo "Failed to start container with standard permissions, trying with sudo..."
    sudo docker run -d --rm --privileged \\
      --device=/dev/accel0 \\
      -e PJRT_DEVICE=TPU \\
      -e XLA_USE_BF16=1 \\
      -e PYTHONUNBUFFERED=1 \\
      -v /tmp/dev/src:/app/dev/src \\
      -w /app \\
      gcr.io/$PROJECT_ID/tpu-hello-world:v1 \\
      /bin/bash -c "echo 'Container started, waiting for commands.' && sleep infinity"
  fi
  
  echo "New background container started."
else
  echo "Found running containers: \$CONTAINERS"
  echo "Restarting containers..."
  
  for container in \$CONTAINERS; do
    echo "Restarting container \$container..."
    if ! docker restart \$container; then
      echo "Failed with standard permissions, trying with sudo..."
      sudo docker restart \$container
    fi
  done
  
  echo "Container restart completed."
fi
EOF

  # Copy the script to the TPU VM
  gcloud compute tpus tpu-vm scp "$TEMP_SCRIPT" "$TPU_NAME":/tmp/restart_container.sh \
      --zone="$TPU_ZONE" \
      --project="$PROJECT_ID" \
      --worker=all
  
  # Make it executable and run it
  ssh_with_timeout "chmod +x /tmp/restart_container.sh && /tmp/restart_container.sh" 30
  
  # Clean up temporary file
  rm "$TEMP_SCRIPT"
  
  log_success "Container restart completed"
}

# Function to watch for file changes and sync
watch_files() {
  local watch_cmd=""
  local utils=$1
  local specific_files=("${@:2}")
  
  # Check for watch utilities in order of preference
  if command -v inotifywait &> /dev/null; then
    log "Using inotifywait for file watching"
    watch_cmd="inotifywait"
  elif command -v fswatch &> /dev/null; then
    log "Using fswatch for file watching"
    watch_cmd="fswatch"
  else
    log_error "No file watching utility found. Please install inotifywait or fswatch."
    log_warning "On Linux: sudo apt-get install inotify-tools"
    log_warning "On macOS: brew install fswatch"
    log_warning "On Windows: Use WSL and install inotify-tools"
    exit 1
  fi
  
  # Initial sync
  if [ ${#specific_files[@]} -gt 0 ]; then
    sync_files "${specific_files[@]}"
  else
    sync_files
  fi
  
  if [ "$utils" = true ]; then
    sync_utils
  fi
  
  # Start watching
  log "Starting file watch mode. Press Ctrl+C to stop..."
  
  # Define the watch directory
  watch_dir="$SRC_DIR"
  
  case "$watch_cmd" in
    "inotifywait")
      # Use inotifywait for continuous watching
      while true; do
        inotifywait -r -e modify,create,delete "$watch_dir"
        
        # Re-sync files on changes
        if [ ${#specific_files[@]} -gt 0 ]; then
          sync_files "${specific_files[@]}"
        else
          sync_files
        fi
        
        if [ "$utils" = true ]; then
          sync_utils
        fi
        
        if [ "$RESTART_CONTAINER" = true ]; then
          restart_container
        fi
      done
      ;;
    "fswatch")
      # Use fswatch for continuous watching
      fswatch -o "$watch_dir" | while read -r line; do
        log "Change detected: $line"
        
        # Re-sync files on changes
        if [ ${#specific_files[@]} -gt 0 ]; then
          sync_files "${specific_files[@]}"
        else
          sync_files
        fi
        
        if [ "$utils" = true ]; then
          sync_utils
        fi
        
        if [ "$RESTART_CONTAINER" = true ]; then
          restart_container
        fi
      done
      ;;
  esac
}

# Function to check and use Docker Compose watch
use_compose_watch() {
  # Check if Docker Compose is installed and supports watch feature
  if ! command -v docker &> /dev/null; then
    log_error "Docker is not installed or not in PATH"
    return 1
  fi
  
  if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    log_error "Docker Compose is not installed or not in PATH"
    return 1
  fi
  
  # Create Docker Compose configuration file
  create_compose_file
  
  # Check if docker compose supports watch (version 2.22.0+)
  local docker_compose_cmd
  if docker compose version &> /dev/null; then
    docker_compose_cmd="docker compose"
  else
    docker_compose_cmd="docker-compose"
  fi
  
  log "Starting Docker Compose watch mode..."
  log "This will automatically sync and update your code as you make changes."
  log "Press Ctrl+C to stop watching."
  
  # Launch Docker Compose with watch
  cd "$PROJECT_DIR"
  if $docker_compose_cmd watch; then
    log_success "Docker Compose watch started successfully"
    return 0
  else
    log_error "Failed to start Docker Compose watch mode"
    log_warning "Your Docker Compose version may not support watch. Requires version 2.22.0+"
    return 1
  fi
}

# Set up error trapping
trap 'handle_error ${LINENO} $?' ERR

# --- MAIN SCRIPT ---
# Parse command line arguments
RESTART_CONTAINER=false
WATCH_MODE=false
SYNC_UTILS=false
SPECIFIC_MODE=false
COMPOSE_WATCH=false
SPECIFIC_FILES=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --restart)
      RESTART_CONTAINER=true
      shift
      ;;
    --watch)
      WATCH_MODE=true
      shift
      ;;
    --utils)
      SYNC_UTILS=true
      shift
      ;;
    --specific)
      SPECIFIC_MODE=true
      shift
      while [[ $# -gt 0 && $1 != --* ]]; do
        SPECIFIC_FILES+=("$1")
        shift
      done
      ;;
    --compose-watch)
      COMPOSE_WATCH=true
      shift
      ;;
    -h|--help)
      show_usage
      ;;
    *)
      log_error "Unknown option: $1"
      show_usage
      ;;
  esac
done

log 'Starting TPU code synchronization process...'

log 'Loading environment variables...'
source "$PROJECT_DIR/source/.env"
log 'Environment variables loaded successfully'

# Validate required environment variables
check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_NAME"

log "Configuration:"
log "- Project ID: $PROJECT_ID"
log "- TPU Zone: $TPU_ZONE"
log "- TPU Name: $TPU_NAME"
log "- Restart container: $RESTART_CONTAINER"
log "- Watch mode: $WATCH_MODE"
log "- Sync utils: $SYNC_UTILS"
log "- Compose watch: $COMPOSE_WATCH"

if [ "$SPECIFIC_MODE" = true ]; then
  log "- Specific files: ${SPECIFIC_FILES[*]}"
fi

# Set up authentication if provided
setup_auth

# Check if the source directory exists
if [[ ! -d "$SRC_DIR" ]]; then
  log_error "Source directory '$SRC_DIR' not found"
  exit 1
fi

# Check for Python files in the source directory if not in specific mode
if [[ "$SPECIFIC_MODE" = false ]]; then
  PYTHON_FILES=$(find "$SRC_DIR" -name "*.py" | wc -l)
  if [[ $PYTHON_FILES -eq 0 ]]; then
    log_warning "No Python files found in $SRC_DIR"
    exit 0
  fi
  log "Found $PYTHON_FILES Python files in source directory"
fi

# Use Docker Compose watch if requested
if [[ "$COMPOSE_WATCH" = true ]]; then
  use_compose_watch
  exit $?
fi

# If watch mode is enabled
if [[ "$WATCH_MODE" = true ]]; then
  log "Starting watch mode..."
  
  if [ "$SPECIFIC_MODE" = true ]; then
    watch_files "$SYNC_UTILS" "${SPECIFIC_FILES[@]}"
  else
    watch_files "$SYNC_UTILS"
  fi
else
  # One-time sync
  if [ "$SPECIFIC_MODE" = true ]; then
    sync_files "${SPECIFIC_FILES[@]}"
  else
    sync_files
  fi
  
  if [ "$SYNC_UTILS" = true ]; then
    sync_utils
  fi
  
  if [ "$RESTART_CONTAINER" = true ]; then
    restart_container
  fi
  
  log_success "Code synchronization completed successfully"
  log "To run synced files, use: ./dev/mgt/run.sh [filename.py]"
fi 