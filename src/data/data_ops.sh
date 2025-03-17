#!/bin/bash

# --- Basic setup ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/src/utils/common.sh"

# --- Default values ---
OUTPUT_DIR=""
BUCKET_NAME=""
CONFIG_PATH=""
VERBOSE=false
DATASETS=""

# --- Command to run ---
COMMAND=""

# --- Detect OS and set Python command accordingly ---
# Try to use Conda environment's Python if available
if [[ -n "$CONDA_PREFIX" ]]; then
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
        # Windows path - use Windows-style path with double quotes
        PYTHON_CMD="\"${CONDA_PREFIX//\//\\}\\python.exe\""
    else
        # Unix path
        PYTHON_CMD="$CONDA_PREFIX/bin/python"
    fi
    echo "Using Conda environment Python: $PYTHON_CMD"
else
    # Fall back to system Python
    PYTHON_CMD="python3"
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
        # Running on Windows (Git Bash/MINGW/Cygwin)
        PYTHON_CMD="python"
        echo "Detected Windows environment, using 'python' command"
    fi
fi

# Verify Python command works and has necessary packages
echo "Checking Python environment..."
python -c "import sys; print(f'Python {sys.version} at {sys.executable}')"
python -c "import importlib.util; packages = ['datasets', 'google.cloud']; missing = [p for p in packages if importlib.util.find_spec(p) is None]; exit(1 if missing else 0)" || {
    echo "Warning: Missing required packages. Please install with:"
    echo "pip install datasets google-cloud-storage pyyaml"
}

# --- Functions ---

show_help() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  download-local  Download datasets from Hugging Face to local storage"
    echo "  upload          Upload datasets from local storage to GCS bucket"
    echo "  download-gcs    Download datasets from GCS bucket to local storage"
    echo "  test            Test access to datasets in GCS bucket"
    echo "  clean           Remove datasets from GCS bucket"
    echo ""
    echo "Options:"
    echo "  --output-dir DIR    Directory to save datasets (default: auto-detected)"
    echo "  --bucket-name NAME  Name of GCS bucket (default: from environment)"
    echo "  --config-path PATH  Path to data configuration file"
    echo "  --datasets LIST     Space-separated list of dataset keys to process"
    echo "  --verbose           Enable verbose output"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 download-local --config-path path/to/config.yaml"
    echo "  $0 upload --bucket-name my-bucket --output-dir path/to/datasets"
    echo "  $0 test --bucket-name my-bucket"
    echo "  $0 clean --bucket-name my-bucket --datasets dataset1 dataset2"
}

# Parse command
if [[ $# -lt 1 ]]; then
    show_help
    exit 1
fi

COMMAND="$1"
shift

# Validate command
case "$COMMAND" in
    download-local|upload|download-gcs|test|clean)
        # Valid command
        ;;
    -h|--help)
        show_help
        exit 0
        ;;
    *)
        echo "Error: Unknown command '$COMMAND'"
        show_help
        exit 1
        ;;
esac

# --- Parse options ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --bucket-name)
            BUCKET_NAME="$2"
            shift 2
            ;;
        --config-path)
            CONFIG_PATH="$2"
            shift 2
            ;;
        --datasets)
            shift
            DATASETS=""
            # Collect all dataset names until the next option
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                DATASETS="$DATASETS $1"
                shift
            done
            DATASETS="${DATASETS# }" # Remove leading space
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown option '$1'"
            show_help
            exit 1
            ;;
    esac
done

# --- Setup environment ---

# Determine config path if not provided
if [[ -z "$CONFIG_PATH" ]]; then
    if [[ -f "$PROJECT_DIR/src/exp/configs/data_config.yaml" ]]; then
        CONFIG_PATH="$PROJECT_DIR/src/exp/configs/data_config.yaml"
    elif [[ -f "$PROJECT_DIR/dev/src/exp/configs/data_config.yaml" ]]; then
        CONFIG_PATH="$PROJECT_DIR/dev/src/exp/configs/data_config.yaml"
    elif [[ -f "/app/src/exp/configs/data_config.yaml" ]]; then
        CONFIG_PATH="/app/src/exp/configs/data_config.yaml"
    else
        log_error "Configuration file not found. Please specify with --config-path."
        exit 1
    fi
fi

# Load environment variables
if [[ -f "/app/keys/service-account.json" ]]; then
    # Inside Docker container 
    : ${PROJECT_ID:?Required environment variable PROJECT_ID is not set}
elif [[ -d "/tmp/app/mount" ]]; then
    # On TPU VM
    source "$PROJECT_DIR/source/.env"
    check_env_vars "PROJECT_ID" || exit 1
else
    # Local development
    source "$PROJECT_DIR/source/.env"
    check_env_vars "PROJECT_ID" || exit 1
fi

# If bucket name wasn't provided, use from environment variable
if [[ -z "$BUCKET_NAME" ]]; then
    # Check for BUCKET_NAME in environment or .env
    if [[ -n "${BUCKET_NAME}" ]]; then
        # Already set in environment
        :
    elif grep -q "BUCKET_NAME=" "$PROJECT_DIR/source/.env" 2>/dev/null; then
        # Load from .env if not already loaded
        [[ -z "${BUCKET_NAME}" ]] && source "$PROJECT_DIR/source/.env"
    else
        log_error "BUCKET_NAME not found in environment or .env file"
        exit 1
    fi
fi

# Determine output dir if not provided (use Python utility)
if [[ -z "$OUTPUT_DIR" ]]; then
    # Use standard python command for consistent behavior
    OUTPUT_DIR=$(python -c "from src.utils.data_utils import detect_environment; print(detect_environment()['output_dir'])")
    log "Auto-detected output directory: $OUTPUT_DIR"
fi

# Fix Windows path representation if needed
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    # Convert path to Windows format if needed for commands
    OUTPUT_DIR_WIN=$(echo "$OUTPUT_DIR" | sed 's|/|\\|g')
    log "Converted path for Windows: $OUTPUT_DIR_WIN"
fi

# Setup authentication for GCS operations
if [[ "$COMMAND" != "download-local" ]]; then
    setup_auth
fi

# --- Execute command ---
log_section "Executing $COMMAND"
log "Configuration:"
log "- Config file: $CONFIG_PATH"
log "- Output directory: $OUTPUT_DIR"
log "- Bucket name: $BUCKET_NAME"
[[ -n "$DATASETS" ]] && log "- Datasets: $DATASETS"

# Download datasets from Hugging Face to local storage
if [[ "$COMMAND" == "download-local" ]]; then
    log_section "Downloading Datasets from Hugging Face"
    
    # Use direct execution instead of eval for better handling of paths with spaces
    if [[ "$VERBOSE" == "true" ]]; then
        log "Running: python -m src.data.buckets.import_data with output_dir=$OUTPUT_DIR"
    fi
    
    # Execute Python module directly
    python -m src.data.buckets.import_data --output-dir "$OUTPUT_DIR" --config-path "$CONFIG_PATH"
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to download datasets from Hugging Face"
        exit 1
    fi

# Upload datasets from local storage to GCS bucket
elif [[ "$COMMAND" == "upload" ]]; then
    log_section "Uploading Datasets to GCS"
    
    # Check if the bucket exists
    log "Checking if bucket gs://$BUCKET_NAME exists..."
    if ! gsutil ls -b "gs://$BUCKET_NAME" &> /dev/null; then
        log_warning "Bucket gs://$BUCKET_NAME doesn't exist. Creating it..."
        gsutil mb -p "$PROJECT_ID" -l "us-central1" "gs://$BUCKET_NAME"
    fi
    
    # Get dataset keys
    if [[ -z "$DATASETS" ]]; then
        DATASETS=$(python -c "from src.data.core import get_dataset_keys; print(' '.join(get_dataset_keys('$CONFIG_PATH')))")
        if [[ $? -ne 0 || -z "$DATASETS" ]]; then
            log_error "No datasets found in configuration file $CONFIG_PATH"
            exit 1
        fi
    fi
    
    # Upload each dataset
    for dataset_key in $DATASETS; do
        if [[ ! -d "$OUTPUT_DIR/$dataset_key" ]]; then
            log_warning "Dataset $dataset_key not found at $OUTPUT_DIR/$dataset_key"
            continue
        fi
        
        log "Uploading $dataset_key dataset to gs://$BUCKET_NAME/datasets/$dataset_key..."
        gsutil -m cp -r "$OUTPUT_DIR/$dataset_key" "gs://$BUCKET_NAME/datasets/"
        
        if [[ $? -eq 0 ]]; then
            log_success "Successfully uploaded $dataset_key dataset"
        else
            log_error "Failed to upload $dataset_key dataset"
        fi
    done

# Download datasets from GCS bucket to local storage
elif [[ "$COMMAND" == "download-gcs" ]]; then
    log_section "Downloading Datasets from GCS"
    
    # Execute Python module directly
    if [[ "$VERBOSE" == "true" ]]; then
        log "Running: python -m src.data.buckets.down_bucket"
    fi
    
    # Use direct command with proper argument handling
    if [[ -n "$DATASETS" ]]; then
        python -m src.data.buckets.down_bucket --output-dir "$OUTPUT_DIR" --bucket-name "$BUCKET_NAME" --config-path "$CONFIG_PATH" --datasets $DATASETS
    else
        python -m src.data.buckets.down_bucket --output-dir "$OUTPUT_DIR" --bucket-name "$BUCKET_NAME" --config-path "$CONFIG_PATH"
    fi
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to download datasets from GCS"
        exit 1
    fi

# Test access to datasets in GCS bucket
elif [[ "$COMMAND" == "test" ]]; then
    log_section "Testing GCS Access"
    
    # Execute Python module directly
    if [[ "$VERBOSE" == "true" ]]; then
        log "Running: python -m src.data.buckets.test_bucket"
    fi
    
    # Use direct command execution
    python -m src.data.buckets.test_bucket --bucket-name "$BUCKET_NAME" --config-path "$CONFIG_PATH"
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to access datasets from GCS"
        exit 1
    fi

# Clean/remove datasets from GCS bucket
elif [[ "$COMMAND" == "clean" ]]; then
    log_section "Cleaning Datasets from GCS"
    
    # Get dataset keys if not provided
    if [[ -z "$DATASETS" ]]; then
        DATASETS=$(python -c "from src.data.core import get_dataset_keys; print(' '.join(get_dataset_keys('$CONFIG_PATH')))")
        if [[ $? -ne 0 || -z "$DATASETS" ]]; then
            log_error "No datasets found in configuration file $CONFIG_PATH"
            exit 1
        fi
        
        # Confirm deletion of all datasets
        if ! confirm_delete "all datasets from gs://$BUCKET_NAME/datasets/"; then
            log "Operation cancelled by user"
            exit 0
        fi
    else
        # Confirm deletion of specified datasets
        if ! confirm_delete "datasets $DATASETS from gs://$BUCKET_NAME/datasets/"; then
            log "Operation cancelled by user"
            exit 0
        fi
    fi
    
    # Remove each dataset
    for dataset_key in $DATASETS; do
        log "Removing $dataset_key dataset from gs://$BUCKET_NAME/datasets/$dataset_key..."
        gsutil -m rm -r "gs://$BUCKET_NAME/datasets/$dataset_key"
        
        if [[ $? -eq 0 ]]; then
            log_success "Successfully removed $dataset_key dataset"
        else
            log_error "Failed to remove $dataset_key dataset"
        fi
    done
fi

log_success "Command $COMMAND completed successfully!"
exit 0 