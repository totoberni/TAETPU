#!/bin/bash
# Bash wrapper for starting the webapp API server

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../" && pwd)"

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
    echo "  --host [host]      Host to bind the server to (default: 0.0.0.0)"
    echo "  --port [port]      Port to bind the server to (default: 5000)"
    echo "  --debug            Enable debug mode"
    echo "  --help             Display this help message"
}

# --- Parse arguments ---
CONFIG_PATH=""
ENV_PATH=""
HOST="0.0.0.0"
PORT="5000"
DEBUG=""

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
        --host)
            HOST="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --debug)
            DEBUG="--debug"
            shift
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

# --- Default paths if not specified ---
if [ -z "$CONFIG_PATH" ]; then
    # Try to find config file in standard locations
    if [ -f "$PROJECT_DIR/dev/src/utils/logging/log_config.yaml" ]; then
        CONFIG_PATH="$PROJECT_DIR/dev/src/utils/logging/log_config.yaml"
    elif [ -f "$PROJECT_DIR/dev/log_config.yaml" ]; then
        CONFIG_PATH="$PROJECT_DIR/dev/log_config.yaml"
    elif [ -f "$PROJECT_DIR/config/log_config.yaml" ]; then
        CONFIG_PATH="$PROJECT_DIR/config/log_config.yaml"
    else
        log_warning "No configuration file found in standard locations. Using defaults."
    fi
fi

if [ -z "$ENV_PATH" ]; then
    # Try to find .env file in standard locations
    if [ -f "$PROJECT_DIR/source/.env" ]; then
        ENV_PATH="$PROJECT_DIR/source/.env"
    elif [ -f "$PROJECT_DIR/dev/.env" ]; then
        ENV_PATH="$PROJECT_DIR/dev/.env"
    elif [ -f "$PROJECT_DIR/.env" ]; then
        ENV_PATH="$PROJECT_DIR/.env"
    else
        log_warning "No .env file found in standard locations."
    fi
fi

# --- Process management ---
PYTHON_PID_FILE="/tmp/tpu_webapp.pid"

# Check if server is already running
if [ -f "$PYTHON_PID_FILE" ]; then
    PID=$(cat "$PYTHON_PID_FILE")
    if ps -p "$PID" > /dev/null; then
        log_warning "Webapp API server is already running with PID $PID"
        log "To stop it, use: kill $PID"
        exit 0
    else
        log "Removing stale PID file"
        rm "$PYTHON_PID_FILE"
    fi
fi

# --- Start server ---
log "Starting TPU Monitoring Webapp API server..."
if [ -n "$CONFIG_PATH" ]; then
    log "Using configuration file: $CONFIG_PATH"
fi
if [ -n "$ENV_PATH" ]; then
    log "Using environment file: $ENV_PATH"
fi

log "Server will be accessible at http://$HOST:$PORT"

# Build the command arguments
CMD_ARGS=""
if [ -n "$CONFIG_PATH" ]; then
    CMD_ARGS="$CMD_ARGS --config '$CONFIG_PATH'"
fi
if [ -n "$ENV_PATH" ]; then
    CMD_ARGS="$CMD_ARGS --env '$ENV_PATH'"
fi
CMD_ARGS="$CMD_ARGS --host $HOST --port $PORT $DEBUG"

# Run the Python script with nohup to keep it running after terminal closes
log "Launching webapp API server in background mode..."
# Use eval to handle the arguments correctly
eval "nohup python '$SCRIPT_DIR/start_webapp.py' $CMD_ARGS > '/tmp/tpu_webapp.log' 2>&1 &"
PID=$!

# Store the PID
echo $PID > "$PYTHON_PID_FILE"
log "Webapp API server started with PID $PID"
log "Logs are being written to /tmp/tpu_webapp.log"
log "To stop the server: kill $PID" 