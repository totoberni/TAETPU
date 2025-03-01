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

# --- SCRIPT VARIABLES ---
BUCKET_NAME=""
MATRIX_SIZE=2000
DATA_DIR=""
LOG_DIR=""
CONFIG_PATH=""
MONITORING_INTERVAL=30  # seconds
START_MONITORING=true
KEEP_MONITORING=false
MONITOR_TIMEOUT=60  # Maximum time to wait for monitoring to start

# --- DISPLAY USAGE INFORMATION ---
function show_usage() {
  echo "Usage: $0 [options]"
  echo ""
  echo "Run Example TPU Pipeline with Monitoring"
  echo ""
  echo "Options:"
  echo "  -b, --bucket NAME       GCS bucket name (default: from .env)"
  echo "  -s, --matrix-size SIZE  Size of matrices to process (default: 2000)"
  echo "  -d, --data-dir DIR      Directory for data storage (default: from config)"
  echo "  -l, --log-dir DIR       Directory for logs (default: from config)"
  echo "  -c, --config PATH       Path to configuration file (default: auto-detect)"
  echo "  -i, --interval SECONDS  Monitoring interval in seconds (default: 30)"
  echo "  --no-monitoring         Don't start monitoring before running example"
  echo "  --keep-monitoring       Don't stop monitoring after example completes"
  echo "  --monitor-timeout SEC   Maximum time to wait for monitoring (default: 60)"
  echo "  -h, --help              Show this help message"
  echo ""
  echo "Example:"
  echo "  $0 --bucket my-bucket --matrix-size 5000 --interval 10"
  exit 1
}

# --- PARSE COMMAND LINE ARGUMENTS ---
while [[ $# -gt 0 ]]; do
  case $1 in
    -b|--bucket)
      BUCKET_NAME="$2"
      shift 2
      ;;
    -s|--matrix-size)
      MATRIX_SIZE="$2"
      shift 2
      ;;
    -d|--data-dir)
      DATA_DIR="$2"
      shift 2
      ;;
    -l|--log-dir)
      LOG_DIR="$2"
      shift 2
      ;;
    -c|--config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    -i|--interval)
      MONITORING_INTERVAL="$2"
      shift 2
      ;;
    --no-monitoring)
      START_MONITORING=false
      shift
      ;;
    --keep-monitoring)
      KEEP_MONITORING=true
      shift
      ;;
    --monitor-timeout)
      MONITOR_TIMEOUT="$2"
      shift 2
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

# --- INITIALIZATION ---
# Initialize script and display banner
init_script "TPU Example Pipeline"

log "TPU Pipeline Example with Monitoring"
log "===================================="

# --- LOAD ENVIRONMENT VARIABLES ---
log "Loading environment variables..."
if [[ -f "$PROJECT_DIR/source/.env" ]]; then
  source "$PROJECT_DIR/source/.env"
  log_success "Environment variables loaded from .env"
else
  log_warning "No .env file found in source directory"
fi

# --- FIND CONFIG FILE IF NOT SPECIFIED ---
if [[ -z "$CONFIG_PATH" ]]; then
  log "Searching for configuration file..."
  
  # List of potential config file locations in priority order
  POTENTIAL_CONFIG_PATHS=(
    "$PROJECT_DIR/dev/src/utils/logging/log_config.yaml"
    "$PROJECT_DIR/dev/log_config.yaml"
    "$PROJECT_DIR/config/log_config.yaml"
    "$SCRIPT_DIR/utils/logging/log_config.yaml"
  )
  
  for config_file in "${POTENTIAL_CONFIG_PATHS[@]}"; do
    if [[ -f "$config_file" ]]; then
      CONFIG_PATH="$config_file"
      log_success "Found configuration at $CONFIG_PATH"
      break
    fi
  done
  
  if [[ -z "$CONFIG_PATH" ]]; then
    log_warning "No configuration file found. Will use defaults."
  fi
fi

# --- LOAD CONFIGURATION FROM YAML ---
# Extract values from YAML configuration using a helper function
function yaml_value() {
  local file="$1"
  local key="$2"
  local default="$3"
  
  if [[ -f "$file" ]]; then
    # Use Python to safely extract values from YAML
    local value=$(python3 -c "
import yaml
try:
    with open('$file', 'r') as f:
        config = yaml.safe_load(f)
    # Handle nested keys with dot notation (e.g., 'logging.log_dir')
    keys = '$key'.split('.')
    result = config
    for k in keys:
        if isinstance(result, dict) and k in result:
            result = result[k]
        else:
            result = None
            break
    print(result if result is not None else '$default')
except Exception as e:
    print('$default')
")
    echo "$value"
  else
    echo "$default"
  fi
}

# --- RESOLVE DIRECTORIES FROM CONFIG ---
if [[ -f "$CONFIG_PATH" ]]; then
  log "Loading directories from configuration file..."
  
  # Get log_dir from config if not specified on command line
  if [[ -z "$LOG_DIR" ]]; then
    LOG_DIR=$(yaml_value "$CONFIG_PATH" "base_log_dir" "logs")
    # Check in alternative locations if not found
    if [[ "$LOG_DIR" == "logs" ]]; then
      LOG_DIR=$(yaml_value "$CONFIG_PATH" "logging.log_dir" "$LOG_DIR")
    fi
    log "Using log directory from config: $LOG_DIR"
  fi
  
  # Get data_dir from config if not specified on command line
  if [[ -z "$DATA_DIR" ]]; then
    DATA_DIR=$(yaml_value "$CONFIG_PATH" "data_dir" "/tmp/tpu_data")
    log "Using data directory from config: $DATA_DIR"
  fi
  
  # If bucket name not provided as argument, get from config
  if [[ -z "$BUCKET_NAME" ]]; then
    BUCKET_NAME=$(yaml_value "$CONFIG_PATH" "bucket_name" "$BUCKET_NAME")
    # Check in alternative locations if not found
    if [[ -z "$BUCKET_NAME" ]]; then
      BUCKET_NAME=$(yaml_value "$CONFIG_PATH" "storage.bucket" "$BUCKET_NAME")
    fi
    if [[ -z "$BUCKET_NAME" ]]; then
      BUCKET_NAME=$(yaml_value "$CONFIG_PATH" "bucket_monitor.bucket_name" "$BUCKET_NAME")
    fi
    
    if [[ -n "$BUCKET_NAME" ]]; then
      log "Using bucket name from config: $BUCKET_NAME"
    fi
  fi
fi

# If bucket name still not provided, use the one from .env
if [[ -z "$BUCKET_NAME" ]]; then
  BUCKET_NAME="$BUCKET_NAME"
  log "Using bucket name from .env: $BUCKET_NAME"
fi

# If log_dir not provided, use default
if [[ -z "$LOG_DIR" ]]; then
  LOG_DIR="logs"
  log "Using default log directory: $LOG_DIR"
fi

# If data_dir not provided, use default
if [[ -z "$DATA_DIR" ]]; then
  DATA_DIR="/tmp/tpu_data"
  log "Using default data directory: $DATA_DIR"
fi

# Validate required environment variables
if [[ -z "$BUCKET_NAME" ]]; then
  log_error "No bucket name provided. Use --bucket or set BUCKET_NAME in .env"
  exit 1
fi

# Display configuration
log "Configuration:"
log "- Bucket name: $BUCKET_NAME"
log "- Matrix size: $MATRIX_SIZE"
log "- Data directory: $DATA_DIR"
log "- Log directory: $LOG_DIR"
log "- Configuration file: ${CONFIG_PATH:-'None (using defaults)'}"
log "- Monitoring interval: $MONITORING_INTERVAL seconds"
log "- Start monitoring: $START_MONITORING"
log "- Keep monitoring after completion: $KEEP_MONITORING"
log "- Monitor timeout: $MONITOR_TIMEOUT seconds"

# --- SETUP ERROR HANDLING ---
function cleanup() {
  log "Cleaning up resources..."
  
  # Stop monitoring if it was started and not meant to be kept
  if [[ "$START_MONITORING" = true && "$KEEP_MONITORING" = false ]]; then
    log "Stopping monitoring..."
    python "$PROJECT_DIR/src/start_monitoring.py" stop || log_warning "Failed to stop monitoring"
  fi
  
  log "Cleanup completed"
}

# Trap for cleanup on exit
trap cleanup EXIT

# Trap for error handling
trap 'handle_error ${LINENO} $?' ERR

# --- ENSURE DIRECTORIES EXIST ---
log "Ensuring directories exist..."
ensure_directory "$LOG_DIR"
ensure_directory "$DATA_DIR"

# --- START MONITORING ---
if [[ "$START_MONITORING" = true ]]; then
  log "Starting monitoring system..."
  
  # Create monitoring command
  MONITOR_CMD=("python" "$PROJECT_DIR/src/start_monitoring.py" "start")
  MONITOR_CMD+=("--log-dir" "$LOG_DIR")
  MONITOR_CMD+=("--bucket" "$BUCKET_NAME")
  MONITOR_CMD+=("--interval" "$MONITORING_INTERVAL")
  
  # Add config path if specified
  if [[ -n "$CONFIG_PATH" ]]; then
    MONITOR_CMD+=("--config" "$CONFIG_PATH")
  fi
  
  # Execute monitoring command
  log_success "Running: ${MONITOR_CMD[*]}"
  "${MONITOR_CMD[@]}" || {
    log_error "Failed to start monitoring"
    exit 1
  }
  
  # Wait for monitoring to be ready by checking for indicator file or process
  log "Waiting for monitoring to initialize (timeout: ${MONITOR_TIMEOUT}s)..."
  
  start_time=$(date +%s)
  monitor_ready=false
  
  while [ $(($(date +%s) - start_time)) -lt "$MONITOR_TIMEOUT" ]; do
    # Check if monitoring is ready by looking for indicator file
    if [ -f "${LOG_DIR}/monitoring_ready.flag" ] || [ -f "/tmp/monitoring_ready.flag" ]; then
      monitor_ready=true
      break
    fi
    
    # Check if monitoring process is running
    if pgrep -f "start_monitoring.py.*start" > /dev/null; then
      # Process is running, check if it's been running for at least 3 seconds
      # This is a basic heuristic - if it's been running for a few seconds and hasn't crashed, it's probably OK
      if [ $(($(date +%s) - start_time)) -gt 3 ]; then
        monitor_ready=true
        break
      fi
    else
      # If process isn't running and it's been more than 3 seconds, monitoring has likely failed
      if [ $(($(date +%s) - start_time)) -gt 3 ]; then
        log_error "Monitoring process not found after starting"
        exit 1
      fi
    fi
    
    # Wait a bit before checking again
    sleep 1
  done
  
  if [ "$monitor_ready" = true ]; then
    log_success "Monitoring system initialized"
  else
    log_warning "Timed out waiting for monitoring to initialize, continuing anyway"
  fi
fi

# --- RUN EXAMPLE SCRIPT ---
log "Running TPU pipeline example..."

# Use a more robust method for context detection
detect_execution_context() {
  # Determine execution context based on environment and file access
  if [ -n "$KUBERNETES_SERVICE_HOST" ] || [ -n "$K8S_POD_NAME" ]; then
    echo "kubernetes"
  elif grep -q "docker\|lxc" /proc/1/cgroup 2>/dev/null || [ -f "/.dockerenv" ]; then
    echo "docker"
  elif ping -c 1 -W 1 tpu-vm >/dev/null 2>&1 || hostname | grep -q "tpu-vm"; then
    echo "tpu-vm"
  else
    echo "local"
  fi
}

EXEC_CONTEXT=$(detect_execution_context)
log "Detected execution context: $EXEC_CONTEXT"

# Choose execution method based on context
case "$EXEC_CONTEXT" in
  "local")
    # Running directly on local machine
    log "Running locally from $PROJECT_DIR/dev/src/example.py"
    EXAMPLE_CMD=("python" "$PROJECT_DIR/dev/src/example.py")
    ;;
  "tpu-vm")
    # Running directly on TPU VM (outside container)
    log "Running on TPU VM from $TPU_HOST_PATH/example.py"
    EXAMPLE_CMD=("python" "$TPU_HOST_PATH/example.py")
    ;;
  "docker"|"kubernetes")
    # Running inside container (Docker or K8s)
    log "Running in container from $DOCKER_CONTAINER_PATH/example.py"
    EXAMPLE_CMD=("python" "$DOCKER_CONTAINER_PATH/example.py")
    ;;
  *)
    # Fallback to using run.sh
    if [[ -f "$PROJECT_DIR/dev/mgt/run.sh" ]]; then
      log "Running example.py through run.sh..."
      EXAMPLE_CMD=("$PROJECT_DIR/dev/mgt/run.sh" "example.py")
    else
      log_error "Could not determine execution context and run.sh not found"
      exit 1
    fi
    ;;
esac

# Add common arguments
EXAMPLE_CMD+=("--bucket" "$BUCKET_NAME")
EXAMPLE_CMD+=("--matrix-size" "$MATRIX_SIZE")
EXAMPLE_CMD+=("--data-dir" "$DATA_DIR")

# Add config path if specified
if [[ -n "$CONFIG_PATH" ]]; then
  EXAMPLE_CMD+=("--config" "$CONFIG_PATH")
fi

# Execute the command
log_success "Running command: ${EXAMPLE_CMD[*]}"
"${EXAMPLE_CMD[@]}"
EXAMPLE_EXIT_CODE=$?

# Check example exit code
if [[ $EXAMPLE_EXIT_CODE -eq 0 ]]; then
  log_success "Example completed successfully"
else
  log_error "Example failed with exit code $EXAMPLE_EXIT_CODE"
fi

# --- GENERATE REPORT ---
if [[ "$START_MONITORING" = true ]]; then
  log "Generating monitoring report..."
  
  # Create report command
  REPORT_CMD=("python" "$PROJECT_DIR/src/start_monitoring.py" "report")
  REPORT_CMD+=("--output-dir" "${LOG_DIR}/reports")
  
  # Add config path if specified
  if [[ -n "$CONFIG_PATH" ]]; then
    REPORT_CMD+=("--config" "$CONFIG_PATH")
  fi
  
  # Execute report command
  log_success "Running command: ${REPORT_CMD[*]}"
  "${REPORT_CMD[@]}" || log_warning "Failed to generate monitoring report"
fi

# --- FINAL STATUS ---
if [[ $EXAMPLE_EXIT_CODE -eq 0 ]]; then
  log_success "TPU Pipeline Example completed successfully"
  exit 0
else
  log_error "TPU Pipeline Example failed"
  exit $EXAMPLE_EXIT_CODE
fi 