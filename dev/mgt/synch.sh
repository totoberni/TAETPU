#!/bin/bash

# --- Basic setup ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_DIR/dev/src"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common.sh"

# --- Parse arguments ---
WATCH_MODE=false
RESTART_CONTAINER=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --watch) WATCH_MODE=true; shift ;;
    --restart) RESTART_CONTAINER=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--watch] [--restart]"
      echo "Synchronize files to TPU VM and optionally watch for changes."
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Load environment variables ---
source "$PROJECT_DIR/source/.env"
check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_NAME" || exit 1

# --- Define Docker image and container ---
DOCKER_IMAGE="eu.gcr.io/${PROJECT_ID}/tae-tpu:v1"
CONTAINER_NAME="tae-tpu-dev"

# --- Sync function ---
sync_files() {
  log "Syncing files to TPU VM"
  
  # Create remote directory and clear existing files
  vmssh "mkdir -p /tmp/app/mount && rm -rf /tmp/app/mount/*"
  
  # Copy all files
  gcloud compute tpus tpu-vm scp --recurse "$SRC_DIR/"* "$TPU_NAME":"/tmp/app/mount/" \
      --zone="$TPU_ZONE" \
      --project="$PROJECT_ID" \
      --worker=all
  
  # Update file listing
  vmssh "find /tmp/app/mount -type f > /tmp/app/mount_files.txt" || true
  
  log_success "Files synced successfully"
}

# --- Restart container function ---
restart_container() {
  log "Restarting container on TPU VM"
  
  # Stop any existing container
  vmssh "docker ps -q -f name=$CONTAINER_NAME | xargs -r docker stop"
  vmssh "docker ps -a -q -f name=$CONTAINER_NAME | xargs -r docker rm"
  
  # Start new container
  vmssh "docker run \
    --name $CONTAINER_NAME \
    --rm \
    --detach \
    --privileged \
    --device=/dev/accel0 \
    -v /tmp/app/mount:/app/mount \
    -v /lib/libtpu.so:/lib/libtpu.so \
    $DOCKER_IMAGE \
    sleep infinity"
  
  log_success "Container restarted"
}

# --- Watch function ---
watch_for_changes() {
  log "Starting watch mode (Ctrl+C to stop)"
  
  if command -v inotifywait &> /dev/null; then
    # Use inotifywait
    while true; do
      inotifywait -r -e modify,create,delete "$SRC_DIR"
      sync_files
      [ "$RESTART_CONTAINER" = true ] && restart_container
    done
  else
    # Use polling
    log_warning "inotifywait not found, using polling"
    while true; do
      sleep 5
      TMPFILE=$(mktemp)
      if find "$SRC_DIR" -type f -newer "$TMPFILE" | grep -q .; then
        sync_files
        [ "$RESTART_CONTAINER" = true ] && restart_container
      fi
      rm "$TMPFILE"
    done
  fi
}

# --- Main execution ---
# Perform initial sync
sync_files

# Restart container if requested
[ "$RESTART_CONTAINER" = true ] && restart_container

# Watch for changes if requested
[ "$WATCH_MODE" = true ] && watch_for_changes

exit 0 