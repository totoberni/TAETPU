#!/bin/bash

# --- DETERMINE SCRIPT AND PROJECT DIRECTORIES ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MGT_DIR="$PROJECT_DIR/dev/mgt"
SRC_DIR="$PROJECT_DIR/dev/src"

# --- IMPORT COMMON FUNCTIONS ---
source "$PROJECT_DIR/setup/scripts/common.sh"

show_usage() {
  echo "Usage: $0 [filename1.py filename2.py ...] [--clean] [--utils] [script_args...]"
  echo ""
  echo "Complete workflow: Mount, run, and optionally clean up Python file(s) on the TPU VM."
  echo ""
  echo "Arguments:"
  echo "  filename1.py, filename2.py   Python files to execute (must be in dev/src or dev/src/utils)"
  echo "  --clean                     Optional: Remove file(s) from TPU VM after execution"
  echo "  --utils                     Optional: Mount utils directory"
  echo "  script_args                 Optional: Arguments to pass to the Python scripts"
  echo ""
  echo "Examples:"
  echo "  $0 example.py                  # Mount, run, and keep example.py"
  echo "  $0 model.py --clean            # Mount, run, and clean up model.py"
  echo "  $0 preprocess.py train.py      # Process multiple files sequentially"
  echo "  $0 train.py --epochs 10        # Run with arguments (passed to last file)"
  echo "  $0 example.py --utils          # Mount example.py and utils directory"
  echo ""
  echo "Notes:"
  echo "  - This script can be run from any directory in the codebase"
  echo "  - When passing arguments, they apply to the last Python file only"
  echo "  - The --clean flag must come after all Python files"
  exit 1
}

# --- MAIN SCRIPT ---
# Parse command line arguments
if [ $# -eq 0 ]; then
  show_usage
fi

# Collect all Python files to run and check for flags
FILES_TO_RUN=()
SCRIPT_ARGS=()
CLEAN_AFTER=false
MOUNT_UTILS=false
COLLECTING_FILES=true

for arg in "$@"; do
  if [[ "$arg" == "--clean" ]]; then
    CLEAN_AFTER=true
    COLLECTING_FILES=false
    continue
  elif [[ "$arg" == "--utils" ]]; then
    MOUNT_UTILS=true
    COLLECTING_FILES=false
    continue
  elif [[ "$COLLECTING_FILES" == "true" && "$arg" == *.py ]]; then
    FILES_TO_RUN+=("$arg")
  else
    COLLECTING_FILES=false
    SCRIPT_ARGS+=("$arg")
  fi
done

# Ensure we have at least one file to run
if [ ${#FILES_TO_RUN[@]} -eq 0 ]; then
  log_error "No Python files specified"
  show_usage
fi

log 'Loading environment variables...'
source "$PROJECT_DIR/source/.env"
log 'Environment variables loaded successfully'

# Validate required environment variables
check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_NAME"

log "Starting workflow for: ${FILES_TO_RUN[*]}"
log "Configuration:"
log "- Files to process: ${FILES_TO_RUN[*]}"
log "- Clean after execution: $CLEAN_AFTER"
log "- Mount utils directory: $MOUNT_UTILS"
if [ ${#SCRIPT_ARGS[@]} -gt 0 ]; then
  log "- Script arguments: ${SCRIPT_ARGS[*]}"
fi

# Step 1: Mount files
log "Step 1/3: Mounting file(s) to TPU VM..."
MOUNT_STATUS=0

# Build the mount command based on flags
MOUNT_CMD="$MGT_DIR/mount.sh"
if [[ "$MOUNT_UTILS" == "true" ]]; then
  MOUNT_CMD="$MOUNT_CMD --utils"
fi

# Mount each file individually to avoid stopping if one fails
for file in "${FILES_TO_RUN[@]}"; do
  log "- Mounting $file"
  if $MOUNT_CMD "$file"; then
    log_success "  Successfully mounted $file"
  else
    log_warning "  Failed to mount $file but continuing"
    MOUNT_STATUS=1
  fi
done

if [ $MOUNT_STATUS -eq 0 ]; then
  log_success "Mount successful for all files."
else
  log_warning "Some files may not have been mounted correctly, but continuing with execution."
fi

# Step 2: Run files
log "Step 2/3: Running file(s) on TPU VM..."
if [ ${#SCRIPT_ARGS[@]} -gt 0 ]; then
  "$MGT_DIR/run.sh" "${FILES_TO_RUN[@]}" "${SCRIPT_ARGS[@]}"
else
  "$MGT_DIR/run.sh" "${FILES_TO_RUN[@]}"
fi

RUN_RESULT=$?
if [ $RUN_RESULT -ne 0 ]; then
  log_warning "Script execution returned non-zero exit code: $RUN_RESULT"
fi

# Step 3: Clean up (optional)
if [ "$CLEAN_AFTER" = true ]; then
  log "Step 3/3: Cleaning up file(s) from TPU VM..."
  
  # Create the clean command with auto-confirm to prevent prompts
  CLEAN_CMD="$MGT_DIR/scrap.sh --auto-confirm"
  CLEAN_STATUS=0
  
  if [[ "$MOUNT_UTILS" == "true" ]]; then
    log "Removing utils directory..."
    if $CLEAN_CMD --utils; then
      log_success "Utils directory cleaned"
    else
      log_warning "Failed to clean utils directory"
      CLEAN_STATUS=1
    fi
  fi
  
  for file in "${FILES_TO_RUN[@]}"; do
    log "- Cleaning up $file"
    if $CLEAN_CMD "$file"; then
      log_success "  Successfully removed $file"
    else
      log_warning "  Failed to clean up $file, but continuing"
      CLEAN_STATUS=1
    fi
  done
  
  if [ $CLEAN_STATUS -eq 0 ]; then
    log_success "Cleanup complete."
  else
    log_warning "Some cleanup operations may have failed."
  fi
else
  log "Step 3/3: Skipping cleanup (use --clean flag to clean up automatically)"
fi

log_success "Workflow complete for all files."
if [ "$CLEAN_AFTER" = false ]; then
  log "Files remain mounted on the TPU VM for further iterations."
  log "To remove them later, run: ./dev/mgt/scrap.sh [filename.py]"
fi

exit $RUN_RESULT 