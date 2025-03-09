#!/bin/bash

# --- Determine script and project directories ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_DIR/dev/src"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common.sh"

# --- Usage information ---
show_usage() {
  echo "Usage: $0 [--watch] [--restart]"
  echo ""
  echo "Synchronize files from local dev/src to TPU VM and optionally watch for changes."
  echo ""
  echo "Options:"
  echo "  --watch     Watch for file changes and sync automatically"
  echo "  --restart   Restart container after syncing files"
  echo "  -h, --help  Show this help message"
  exit 1
}

# --- Parse command-line arguments ---
WATCH_MODE=false
RESTART_CONTAINER=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --watch)
      WATCH_MODE=true
      shift
      ;;
    --restart)
      RESTART_CONTAINER=true
      shift
      ;;
    -h|--help)
      show_usage
      ;;
    *)
      echo "Unknown option: $1"
      show_usage
      ;;
  esac
done

# --- Load environment variables ---
source "$PROJECT_DIR/source/.env"

# --- Check required environment variables ---
check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_NAME" || exit 1

# --- Define Docker image path ---
DOCKER_IMAGE="gcr.io/${PROJECT_ID}/tae-tpu:v1"

# --- Paths ---
HOST_MOUNT_PATH="/tmp/app/mount"
CONTAINER_MOUNT_PATH="/app/mount"
CONTAINER_NAME="tae-tpu-dev"

# --- Function to sync files ---
sync_files() {
  log "Syncing files to TPU VM..."
  
  # Create target directory if it doesn't exist
  vmssh "mkdir -p $HOST_MOUNT_PATH" || return 1
  
  # Create temporary directory for staging
  TEMP_DIR=$(mktemp -d)
  trap 'rm -rf $TEMP_DIR' EXIT
  
  # Copy source files to temp directory
  if [ -d "$SRC_DIR" ]; then
    cp -r "$SRC_DIR/"* "$TEMP_DIR/" 2>/dev/null || true
  else
    log_error "Source directory $SRC_DIR does not exist!"
    return 1
  fi
  
  # Transfer files to TPU VM
  if [ -z "$(ls -A "$TEMP_DIR")" ]; then
    log_warning "No files to transfer"
  else
    # Clear the target directory first to avoid stale files
    vmssh "rm -rf $HOST_MOUNT_PATH/*"
    
    gcloud compute tpus tpu-vm scp --recurse "$TEMP_DIR/"* "$TPU_NAME":"$HOST_MOUNT_PATH/" \
        --zone="$TPU_ZONE" \
        --project="$PROJECT_ID" \
        --worker=all
  fi
  
  log_success "Files synced successfully to $HOST_MOUNT_PATH"
  return 0
}

# --- Function to restart container ---
restart_container() {
  log "Restarting container..."
  
  # Check if container is running
  CONTAINER_RUNNING=$(vmssh "docker ps -q -f name=$CONTAINER_NAME")
  
  if [[ -n "$CONTAINER_RUNNING" ]]; then
    # Stop existing container
    vmssh "docker stop $CONTAINER_NAME"
    vmssh "docker rm $CONTAINER_NAME"
  fi
  
  # Start new container with proper Docker flags
  vmssh "docker run \
    --name $CONTAINER_NAME \
    --rm \
    --detach \
    --privileged \
    --device=/dev/accel0 \
    --env PJRT_DEVICE=TPU \
    --env XLA_USE_BF16=1 \
    --env PYTHONUNBUFFERED=1 \
    --volume $HOST_MOUNT_PATH:$CONTAINER_MOUNT_PATH \
    --workdir /app \
    $DOCKER_IMAGE \
    sleep infinity"
  
  if [ $? -eq 0 ]; then
    log_success "Container restarted successfully"
    return 0
  else
    log_error "Failed to restart container"
    return 1
  fi
}

# --- Function to watch for changes ---
watch_for_changes() {
  log "Starting watch mode. Press Ctrl+C to stop..."
  
  # Initial sync
  sync_files
  
  if [ "$RESTART_CONTAINER" = true ]; then
    restart_container
  fi
  
  # Check for required tools
  if command -v inotifywait &> /dev/null; then
    # Use inotifywait for file watching
    while true; do
      log "Watching for changes in $SRC_DIR..."
      inotifywait -r -e modify,create,delete "$SRC_DIR"
      
      # Sync files when changes detected
      sync_files
      
      if [ "$RESTART_CONTAINER" = true ]; then
        restart_container
      fi
    done
  else
    # Fallback to polling
    log_warning "inotifywait not found. Using polling instead (may increase CPU usage)."
    log_warning "Install inotify-tools for more efficient file watching."
    
    while true; do
      sleep 5
      
      # Check for changes by simple timestamp file
      TMPFILE=$(mktemp)
      find "$SRC_DIR" -type f -newer "$TMPFILE" | grep -q . && {
        log "Changes detected"
        sync_files
        
        if [ "$RESTART_CONTAINER" = true ]; then
          restart_container
        fi
      }
      rm "$TMPFILE"
    done
  fi
}

# --- Main execution ---
log "TPU File Synchronization"
log "- TPU Name: $TPU_NAME"
log "- Watch Mode: $WATCH_MODE"
log "- Restart Container: $RESTART_CONTAINER"
log "- Docker Image: $DOCKER_IMAGE"

# Perform initial sync
sync_files || exit 1

# Restart container if requested
if [ "$RESTART_CONTAINER" = true ]; then
  restart_container || exit 1
fi

# Watch for changes if requested
if [ "$WATCH_MODE" = true ]; then
  watch_for_changes
else
  log_success "Synchronization completed successfully"
fi

exit 0 