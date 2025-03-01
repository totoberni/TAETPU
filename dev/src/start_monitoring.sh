#!/bin/bash
# Bash wrapper for starting the monitoring system

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../../../" && pwd)"

# --- Colors for pretty output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# --- Functions ---
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

print_usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  --config [path]    Path to configuration file (YAML)"
    echo "  --env [path]       Path to environment file (.env)"
    echo "  --webapp           Start the webapp API server alongside monitoring"
    echo "  --log-dir [path]   Override log directory from config"
    echo "  --interval [sec]   Override monitoring interval from config"
    echo "  --bucket [name]    Override bucket name from config"
    echo "  --help             Display this help message"
}

# Function to find a configuration file
find_config_file() {
    # List of potential config file locations in priority order
    POTENTIAL_CONFIG_PATHS=(
        "$PROJECT_DIR/dev/src/utils/logging/log_config.yaml"
        "$PROJECT_DIR/dev/log_config.yaml"
        "$PROJECT_DIR/config/log_config.yaml"
        "$SCRIPT_DIR/utils/logging/log_config.yaml"
    )
    
    for config_file in "${POTENTIAL_CONFIG_PATHS[@]}"; do
        if [[ -f "$config_file" ]]; then
            echo "$config_file"
            return 0
        fi
    done
    
    return 1
}

# Function to extract values from YAML
yaml_value() {
    local file="$1"
    local key="$2"
    local default="$3"
    
    if [[ -f "$file" ]]; then
        # Use Python to extract the value
        python3 -c "
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
"
    else
        echo "$default"
    fi
}

# --- Parse arguments ---
CONFIG_PATH=""
ENV_PATH=""
START_WEBAPP=""
LOG_DIR=""
INTERVAL=""
BUCKET_NAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --config)
            CONFIG_PATH="$2"
            shift 2
            ;;
        --env)
            ENV_PATH="$2"
            shift 2
            ;;
        --webapp)
            START_WEBAPP="--webapp"
            shift
            ;;
        --log-dir)
            LOG_DIR="$2"
            shift 2
            ;;
        --interval)
            INTERVAL="$2"
            shift 2
            ;;
        --bucket)
            BUCKET_NAME="$2"
            shift 2
            ;;
        --help)
            print_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# --- Find configuration file if not specified ---
if [ -z "$CONFIG_PATH" ]; then
    CONFIG_PATH=$(find_config_file)
    if [ -n "$CONFIG_PATH" ]; then
        log "Using config from: $CONFIG_PATH"
    else
        log_warning "No configuration file found in standard locations. Using defaults."
    fi
fi

# --- Find .env file if not specified ---
if [ -z "$ENV_PATH" ]; then
    # Try to find .env file in standard locations
    if [ -f "$PROJECT_DIR/source/.env" ]; then
        ENV_PATH="$PROJECT_DIR/source/.env"
        log "Using environment file from: $ENV_PATH"
    elif [ -f "$PROJECT_DIR/dev/.env" ]; then
        ENV_PATH="$PROJECT_DIR/dev/.env"
        log "Using environment file from: $ENV_PATH"
    elif [ -f "$PROJECT_DIR/.env" ]; then
        ENV_PATH="$PROJECT_DIR/.env"
        log "Using environment file from: $ENV_PATH"
    else
        log_warning "No .env file found in standard locations."
    fi
fi

# --- Load configuration values from YAML if available ---
if [ -n "$CONFIG_PATH" ]; then
    log "Loading configuration values from $CONFIG_PATH"
    
    # Only set these values if not explicitly provided via command line
    if [ -z "$LOG_DIR" ]; then
        # Try different config keys for log directory
        LOG_DIR=$(yaml_value "$CONFIG_PATH" "base_log_dir" "")
        if [ -z "$LOG_DIR" ]; then
            LOG_DIR=$(yaml_value "$CONFIG_PATH" "logging.log_dir" "logs")
        fi
        log "Using log directory from config: $LOG_DIR"
    fi
    
    if [ -z "$INTERVAL" ]; then
        # Try different config keys for interval
        INTERVAL=$(yaml_value "$CONFIG_PATH" "monitoring.interval" "")
        if [ -z "$INTERVAL" ]; then
            INTERVAL=$(yaml_value "$CONFIG_PATH" "tpu_monitor.sampling_interval" "30")
        fi
        log "Using monitoring interval from config: $INTERVAL seconds"
    fi
    
    if [ -z "$BUCKET_NAME" ]; then
        # Try different config keys for bucket name
        BUCKET_NAME=$(yaml_value "$CONFIG_PATH" "bucket_name" "")
        if [ -z "$BUCKET_NAME" ]; then
            BUCKET_NAME=$(yaml_value "$CONFIG_PATH" "storage.bucket" "")
        fi
        if [ -z "$BUCKET_NAME" ]; then
            BUCKET_NAME=$(yaml_value "$CONFIG_PATH" "bucket_monitor.bucket_name" "")
        fi
        
        if [ -n "$BUCKET_NAME" ]; then
            log "Using bucket name from config: $BUCKET_NAME"
        fi
    fi
else
    # Set defaults if no config file
    [ -z "$LOG_DIR" ] && LOG_DIR="logs"
    [ -z "$INTERVAL" ] && INTERVAL="30"
fi

# --- Load environment variables ---
if [ -n "$ENV_PATH" ]; then
    log "Loading environment variables from $ENV_PATH"
    source "$ENV_PATH"
    
    # Use bucket name from .env if not set via config or command line
    if [ -z "$BUCKET_NAME" ] && [ -n "$BUCKET_NAME" ]; then
        BUCKET_NAME="$BUCKET_NAME"
        log "Using bucket name from .env: $BUCKET_NAME"
    fi
fi

# --- Process management ---
PYTHON_PID_FILE="/tmp/tpu_monitoring.pid"

# Check if monitoring is already running
if [ -f "$PYTHON_PID_FILE" ]; then
    PID=$(cat "$PYTHON_PID_FILE")
    if ps -p "$PID" > /dev/null; then
        log_warning "Monitoring is already running with PID $PID"
        log "To stop it, use: kill $PID"
        exit 0
    else
        log "Removing stale PID file"
        rm "$PYTHON_PID_FILE"
    fi
fi

# --- Start monitoring ---
log "Starting TPU monitoring system..."

# Build the command arguments
CMD_ARGS="start"
if [ -n "$CONFIG_PATH" ]; then
    CMD_ARGS="$CMD_ARGS --config '$CONFIG_PATH'"
fi
if [ -n "$ENV_PATH" ]; then
    CMD_ARGS="$CMD_ARGS --env '$ENV_PATH'"
fi
if [ -n "$LOG_DIR" ]; then
    CMD_ARGS="$CMD_ARGS --log-dir '$LOG_DIR'"
fi
if [ -n "$INTERVAL" ]; then
    CMD_ARGS="$CMD_ARGS --interval '$INTERVAL'"
fi
if [ -n "$BUCKET_NAME" ]; then
    CMD_ARGS="$CMD_ARGS --bucket '$BUCKET_NAME'"
fi
if [ -n "$START_WEBAPP" ]; then
    CMD_ARGS="$CMD_ARGS $START_WEBAPP"
fi

# Run the Python script with nohup to keep it running after terminal closes
log "Launching monitoring in background mode..."
# Use eval to handle the arguments correctly
eval "nohup python '$SCRIPT_DIR/start_monitoring.py' $CMD_ARGS > '/tmp/tpu_monitoring.log' 2>&1 &"
PID=$!

# Store the PID
echo $PID > "$PYTHON_PID_FILE"
log "Monitoring started with PID $PID"
log "Logs are being written to /tmp/tpu_monitoring.log"

if [ -n "$START_WEBAPP" ]; then
    log "Webapp API server is also started (logs are included in the monitoring log)"
    echo "You can access the API at: http://localhost:5000/api/status"
fi
log "To stop monitoring: kill $PID" 