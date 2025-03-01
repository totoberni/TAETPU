#!/bin/bash

# --- DETERMINE SCRIPT AND PROJECT DIRECTORIES ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- DEFINE PATH CONSTANTS - Use these consistently across all scripts ---
TPU_HOST_PATH="/tmp/dev/src"
DOCKER_CONTAINER_PATH="/app/dev/src"

# --- IMPORT COMMON FUNCTIONS ---
source "$PROJECT_DIR/src/utils/common_logging.sh"

# --- HELPER FUNCTIONS ---
show_usage() {
  echo "Usage: $0 [options] file1.py [file2.py ...] [script_args...]"
  echo ""
  echo "Mount, run, and optionally clean up files on TPU VM"
  echo ""
  echo "Options:"
  echo "  --clean       Clean up files after running"
  echo "  --utils       Mount utils directory (automatically done if needed)"
  echo "  -h, --help    Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 example.py                # Mount and run example.py"
  echo "  $0 --clean example.py        # Mount, run, then clean up example.py"
  echo "  $0 example.py --epochs 10    # Mount and run with arguments"
  echo ""
  echo "Note: You can supply multiple files to be run sequentially."
  exit 1
}

# --- MAIN SCRIPT ---
# Process command line arguments
CLEAN_UP=false
MOUNT_UTILS=false
FILES_TO_PROCESS=()
RUN_ARGS=()
COLLECTING_FILES=true

if [ $# -eq 0 ]; then
  show_usage
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    --clean)
      CLEAN_UP=true
      shift
      ;;
    --utils)
      MOUNT_UTILS=true
      shift
      ;;
    -h|--help)
      show_usage
      ;;
    *)
      if [[ "$COLLECTING_FILES" == "true" && ("$1" == *.py || "$1" == *.sh) ]]; then
        FILES_TO_PROCESS+=("$1")
      else
        COLLECTING_FILES=false
        RUN_ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

log "Starting mount-run-scrap process..."

# Check if files to process were specified
if [ ${#FILES_TO_PROCESS[@]} -eq 0 ]; then
  log_error "No files specified to process"
  show_usage
fi

log "Configuration:"
log "- Files to process: ${FILES_TO_PROCESS[*]}"
log "- Clean up after: $CLEAN_UP"
log "- Mount utils: $MOUNT_UTILS"
if [ ${#RUN_ARGS[@]} -gt 0 ]; then
  log "- Run arguments: ${RUN_ARGS[*]}"
else
  log "- Run arguments: none"
fi

# Step 1: Mount files
log "Step 1: Mounting files to TPU VM..."

# Mount utils directory if specified or needed by any Python file
if [[ "$MOUNT_UTILS" == "true" ]]; then
  if [[ -f "$PROJECT_DIR/dev/mgt/mount.sh" ]]; then
    log "Mounting utils directory..."
    "$PROJECT_DIR/dev/mgt/mount.sh" --utils
    if [ $? -ne 0 ]; then
      log_error "Failed to mount utils directory"
      exit 1
    fi
  else
    log_error "mount.sh not found"
    exit 1
  fi
fi

# Mount each specified file
for file in "${FILES_TO_PROCESS[@]}"; do
  if [[ -f "$PROJECT_DIR/dev/mgt/mount.sh" ]]; then
    log "Mounting $file..."
    "$PROJECT_DIR/dev/mgt/mount.sh" "$file"
    if [ $? -ne 0 ]; then
      log_error "Failed to mount $file"
      exit 1
    fi
  else
    log_error "mount.sh not found"
    exit 1
  fi
done

# Step 2: Run files
log "Step 2: Running files on TPU VM..."
if [[ -f "$PROJECT_DIR/dev/mgt/run.sh" ]]; then
  run_cmd=("$PROJECT_DIR/dev/mgt/run.sh" "${FILES_TO_PROCESS[@]}")
  if [ ${#RUN_ARGS[@]} -gt 0 ]; then
    run_cmd+=("${RUN_ARGS[@]}")
  fi
  
  log "Executing: ${run_cmd[*]}"
  "${run_cmd[@]}"
  run_result=$?
  
  if [ $run_result -ne 0 ]; then
    log_warning "Run command returned non-zero exit code: $run_result"
  else
    log_success "Run command completed successfully"
  fi
else
  log_error "run.sh not found"
  exit 1
fi

# Step 3: Clean up (optional)
if [[ "$CLEAN_UP" == "true" ]]; then
  log "Step 3: Cleaning up files from TPU VM..."
  if [[ -f "$PROJECT_DIR/dev/mgt/scrap.sh" ]]; then
    for file in "${FILES_TO_PROCESS[@]}"; do
      log "Cleaning up $file..."
      "$PROJECT_DIR/dev/mgt/scrap.sh" "$file"
      if [ $? -ne 0 ]; then
        log_warning "Failed to clean up $file"
      fi
    done
    log_success "Clean-up process completed"
  else
    log_error "scrap.sh not found"
    exit 1
  fi
else
  log "Step 3: Skipping clean-up (not requested)"
fi

log_success "Mount-run-scrap process completed with exit code: $run_result"
exit $run_result 