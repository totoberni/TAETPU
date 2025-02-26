#!/bin/bash

# --- HELPER FUNCTIONS ---
log() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] $1"
}

handle_error() {
  local line_no=$1
  local error_code=$2
  log "ERROR: Command failed at line $line_no with exit code $error_code"
  exit $error_code
}

show_usage() {
  echo "Usage: $0 [filename1.py filename2.py ...] [--clean] [script_args...]"
  echo ""
  echo "Complete workflow: Mount, run, and optionally clean up Python file(s) on the TPU VM."
  echo ""
  echo "Arguments:"
  echo "  filename1.py, filename2.py  Python files to execute (must be in dev/src)"
  echo "  --clean                     Optional: Remove file(s) from TPU VM after execution"
  echo "  script_args                 Optional: Arguments to pass to the Python script(s)"
  echo ""
  echo "Examples:"
  echo "  $0 example.py                  # Mount, run, and keep example.py"
  echo "  $0 model.py --clean            # Mount, run, and clean up model.py"
  echo "  $0 preprocess.py train.py      # Process multiple files sequentially"
  echo "  $0 train.py --epochs 10        # Run with arguments (passed to last file)"
  echo ""
  echo "Notes:"
  echo "  - This script can be run from any directory in the codebase"
  echo "  - When passing arguments, they apply to the last Python file only"
  echo "  - The --clean flag must come after all Python files"
  exit 1
}

# Set up error trapping
trap 'handle_error ${LINENO} $?' ERR

# --- MAIN SCRIPT ---
# Get the absolute path to the project root directory - works from any directory
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
MGT_DIR="$PROJECT_DIR/dev/mgt"
SRC_DIR="$PROJECT_DIR/dev/src"

# Parse command line arguments
if [ $# -eq 0 ]; then
  show_usage
fi

# Collect all Python files to run and check for the clean flag
FILES_TO_RUN=()
SCRIPT_ARGS=()
CLEAN_AFTER=false
COLLECTING_FILES=true

for arg in "$@"; do
  if [[ "$arg" == "--clean" ]]; then
    CLEAN_AFTER=true
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
  log "ERROR: No Python files specified"
  show_usage
fi

log "Starting comprehensive workflow for: ${FILES_TO_RUN[*]}"

log "Configuration:"
log "- Files to process: ${FILES_TO_RUN[*]}"
log "- Clean after execution: $CLEAN_AFTER"
if [ ${#SCRIPT_ARGS[@]} -gt 0 ]; then
  log "- Script arguments: ${SCRIPT_ARGS[*]}"
fi

# Step 1: Mount all files
log "Step 1/3: Mounting file(s) to TPU VM..."
for FILE_TO_RUN in "${FILES_TO_RUN[@]}"; do
  log "- Mounting $FILE_TO_RUN"
  "$MGT_DIR/mount.sh" "$FILE_TO_RUN"
  if [ $? -ne 0 ]; then
    log "ERROR: Failed to mount file '$FILE_TO_RUN'. Aborting."
    exit 1
  fi
done
log "Mount successful for all files."

# Step 2: Run all files
log "Step 2/3: Running file(s) on TPU VM..."
if [ ${#SCRIPT_ARGS[@]} -gt 0 ]; then
  "$MGT_DIR/run.sh" "${FILES_TO_RUN[@]}" "${SCRIPT_ARGS[@]}"
else
  "$MGT_DIR/run.sh" "${FILES_TO_RUN[@]}"
fi

RUN_RESULT=$?
if [ $RUN_RESULT -ne 0 ]; then
  log "WARNING: Script execution returned non-zero exit code: $RUN_RESULT"
fi

# Step 3: Clean up (optional)
if [ "$CLEAN_AFTER" = true ]; then
  log "Step 3/3: Cleaning up file(s) from TPU VM..."
  for FILE_TO_RUN in "${FILES_TO_RUN[@]}"; do
    log "- Cleaning up $FILE_TO_RUN"
    "$MGT_DIR/scrap.sh" "$FILE_TO_RUN"
    if [ $? -ne 0 ]; then
      log "WARNING: Failed to clean up file '$FILE_TO_RUN'"
    fi
  done
  log "Cleanup complete."
else
  log "Step 3/3: Skipping cleanup (use --clean flag to clean up automatically)"
fi

log "Workflow complete for all files."
if [ "$CLEAN_AFTER" = false ]; then
  log "Files remain mounted on the TPU VM for further iterations."
  log "To remove them later, run: ./dev/mgt/scrap.sh [filename.py]"
fi 