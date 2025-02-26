#!/bin/bash

# --- DETERMINE SCRIPT AND PROJECT DIRECTORIES ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- IMPORT COMMON FUNCTIONS ---
source "$PROJECT_DIR/setup/scripts/common.sh"

# --- HELPER FUNCTIONS (copied from common.sh to avoid cross-referencing) ---
log() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] $1"
}

log_success() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "[$timestamp] \033[0;32m$1\033[0m"  # Green
}

log_warning() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "[$timestamp] \033[0;33m$1\033[0m"  # Yellow
}

log_error() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "[$timestamp] \033[0;31m$1\033[0m"  # Red
}

handle_error() {
  local line_no=$1
  local error_code=$2
  log_error "Command failed at line $line_no with exit code $error_code"
  exit $error_code
}

# Set up error trapping
trap 'handle_error ${LINENO} $?' ERR

# --- Helper utilities ---
# Note: check_env_vars is now imported from common.sh

ensure_directory() {
  local dir=$1
  if [[ ! -d "$dir" ]]; then
    log "Creating directory: $dir"
    mkdir -p "$dir"
  fi
}

# --- Dependency Checks ---
check_dependencies() {
  # Check for jq dependency
  if ! command -v jq &> /dev/null; then
    log_error "Required dependency 'jq' is not installed. Please install it first."
    log_warning "On Linux: sudo apt-get install jq"
    log_warning "On macOS: brew install jq"
    log_warning "On Windows: Install through chocolatey or download from https://stedolan.github.io/jq/"
    return 1
  fi
  
  # Check for gcloud
  if ! command -v gcloud &> /dev/null; then
    log_error "Google Cloud SDK (gcloud) is not installed or not in PATH"
    return 1
  fi
  
  # Check for required environment variables
  check_env_vars "PROJECT_ID" "TPU_ZONE" "TPU_NAME"
  return $?
}

# --- TPU Monitoring Functions ---
monitor_tpu_usage() {
  local tpu_name=$1
  local output_file=${2:-"logs/tpu_usage.log"}
  local interval=${3:-60}  # seconds
  local pid_file="logs/.tpu_monitor_${tpu_name}.pid"
  
  log "Starting TPU usage monitoring for $tpu_name (logged to $output_file)"
  ensure_directory "$(dirname "$output_file")"
  ensure_directory "$(dirname "$pid_file")"
  
  # Run in background
  (
    while true; do
      timestamp=$(date '+%Y-%m-%d %H:%M:%S')
      tpu_info=$(gcloud compute tpus tpu-vm describe "$tpu_name" \
        --zone="$TPU_ZONE" \
        --project="$PROJECT_ID" \
        --format="json" 2>/dev/null)
      
      if [ $? -eq 0 ]; then
        # Use jq safely with fallbacks
        if ! state=$(echo "$tpu_info" | jq -r '.state' 2>/dev/null); then
          state="UNKNOWN"
        fi
        
        if ! health=$(echo "$tpu_info" | jq -r '.health' 2>/dev/null); then
          health="UNKNOWN"
        fi
        
        echo "[$timestamp] TPU: $tpu_name, State: $state, Health: $health" >> "$output_file"
        
        # Collect additional metrics if possible
        if [ "$health" == "HEALTHY" ]; then
          # Execute command inside TPU VM to get utilization metrics
          gcloud compute tpus tpu-vm ssh "$tpu_name" \
            --zone="$TPU_ZONE" \
            --project="$PROJECT_ID" \
            --command="cat /sys/class/tpu/tpu0/tpu_utilization 2>/dev/null || echo 'N/A'" \
            > /tmp/tpu_utilization.txt 2>/dev/null
          
          if [ $? -eq 0 ]; then
            utilization=$(cat /tmp/tpu_utilization.txt)
            echo "[$timestamp] TPU Utilization: $utilization" >> "$output_file"
          else
            echo "[$timestamp] Warning: Could not collect TPU utilization metrics" >> "$output_file"
          fi
        fi
      else
        echo "[$timestamp] Error: Could not get TPU status" >> "$output_file"
      fi
      
      sleep $interval
    done
  ) &
  
  echo $! > "$pid_file"
  log_success "TPU monitoring started with PID $(cat "$pid_file")"
}

stop_tpu_monitoring() {
  local tpu_name=${1:-$TPU_NAME}
  local pid_file="logs/.tpu_monitor_${tpu_name}.pid"
  
  if [ -f "$pid_file" ]; then
    pid=$(cat "$pid_file")
    log "Stopping TPU monitoring for $tpu_name (PID: $pid)"
    
    # Check if process is still running before attempting to kill
    if ps -p "$pid" > /dev/null; then
      kill $pid 2>/dev/null || true
      log_success "Stopped TPU monitoring process"
    else
      log_warning "TPU monitoring process not running (PID: $pid)"
    fi
    
    rm "$pid_file"
  else
    log_warning "No active TPU monitoring found for $tpu_name"
  fi
}

# --- Performance metrics collection ---
collect_python_performance() {
  local log_file=${1:-"logs/performance.log"}
  local pid=$2
  local pid_file="logs/.pyspy_monitor.pid"
  
  if [ -z "$pid" ]; then
    log_error "ERROR: No PID provided for performance monitoring"
    return 1
  fi
  
  log "Collecting performance metrics for PID $pid"
  ensure_directory "$(dirname "$log_file")"
  ensure_directory "$(dirname "$pid_file")"
  
  # Install py-spy if not already available
  if ! command -v py-spy &> /dev/null; then
    log "Installing py-spy..."
    pip install py-spy
    
    # Verify installation
    if ! command -v py-spy &> /dev/null; then
      log_error "Failed to install py-spy. Please install it manually."
      return 1
    fi
  fi
  
  # Ensure the target process exists
  if ! ps -p "$pid" > /dev/null; then
    log_error "Process with PID $pid does not exist"
    return 1
  fi
  
  # Generate CPU flame graph
  local flamegraph_path="logs/flamegraph_$(date +%Y%m%d_%H%M%S).svg"
  py-spy record -o "$flamegraph_path" --pid $pid &
  echo $! > "$pid_file"
  
  log_success "Performance monitoring started (flamegraph will be saved to $flamegraph_path)"
}

stop_performance_monitoring() {
  local pid_file="logs/.pyspy_monitor.pid"
  
  if [ -f "$pid_file" ]; then
    pid=$(cat "$pid_file")
    log "Stopping performance monitoring (PID: $pid)"
    
    # Check if process is still running
    if ps -p "$pid" > /dev/null; then
      kill $pid 2>/dev/null || true
      log_success "Stopped performance monitoring process"
    else
      log_warning "Performance monitoring process not running (PID: $pid)"
    fi
    
    rm "$pid_file"
  else
    log_warning "No active performance monitoring found"
  fi
}

# --- Integrated monitoring start/stop ---
start_monitoring() {
  local tpu_name=$1
  local python_pid=$2
  
  # Check dependencies before starting
  if ! check_dependencies; then
    log_error "Failed dependency check. Cannot start monitoring."
    exit 1
  fi
  
  log "Starting comprehensive monitoring"
  
  # Create logs directory if it doesn't exist
  ensure_directory "logs"
  
  # Start TPU monitoring
  monitor_tpu_usage "$tpu_name" "logs/tpu_${tpu_name}_usage.log" 30
  
  # Start Python process monitoring if PID provided
  if [ -n "$python_pid" ]; then
    collect_python_performance "logs/performance_${python_pid}.log" "$python_pid"
  else
    log_warning "No Python PID provided. Only TPU monitoring will be enabled."
  fi
  
  log_success "All monitoring services started"
}

stop_monitoring() {
  log "Stopping all monitoring services"
  
  # Stop TPU monitoring for the default TPU
  stop_tpu_monitoring
  
  # Stop performance monitoring
  stop_performance_monitoring
  
  log_success "All monitoring services stopped"
}

# --- Main Script ---
if [ "$1" == "start" ]; then
  if [ -z "$2" ]; then
    log_error "TPU name is required for 'start' command"
    echo "Usage: $0 start TPU_NAME [PYTHON_PID]"
    exit 1
  fi
  start_monitoring "$2" "$3"
elif [ "$1" == "stop" ]; then
  stop_monitoring
else
  echo "Usage: $0 start TPU_NAME [PYTHON_PID]"
  echo "       $0 stop"
  exit 1
fi 