#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/infrastructure/utils/common.sh"
load_env_vars "$PROJECT_DIR/config/.env"

# --- Default values ---
OUTPUT_DIR="downloads"  # Use a simple relative path
BUCKET_NAME="${BUCKET_NAME:-}"
DATASETS=""

# --- Functions ---
show_help() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  download-local  Download datasets from Hugging Face to local storage"
    echo "  upload          Upload datasets from local storage to GCS bucket"
    echo "  download-gcs    Download datasets from GCS bucket to local storage"
    echo "  clean           Remove datasets from GCS bucket"
    echo "  list            List all blobs/files in the GCS bucket"
    echo "  count           Count files in GCS bucket datasets"
    echo ""
    echo "Options:"
    echo "  --output-dir DIR    Directory to save datasets (default: $OUTPUT_DIR)"
    echo "  --bucket-name NAME  Name of GCS bucket (default: from environment)"
    echo "  --datasets LIST     Space-separated list of dataset keys to process"
    echo "  -h, --help          Show this help message"
}

# Get dataset keys and names from environment variables
get_dataset_info() {
    local dataset_key="$1"
    
    # Convert to uppercase for env var lookup
    local key_upper=$(echo "$dataset_key" | tr '[:lower:]' '[:upper:]')
    local var_name="DATASET_${key_upper}_NAME"
    
    # Get value from environment variable
    local dataset_name="${!var_name}"
    
    if [[ -n "$dataset_name" ]]; then
        echo "$dataset_key $dataset_name"
    fi
}

# List all available datasets from environment variables in a Windows Git Bash compatible way (cursed counter = 1)
list_available_datasets() {
    # Create an array to hold results
    local dataset_keys=()
    
    # Get all variable names
    while IFS= read -r var_name; do
        # Trim any whitespace or special characters
        var_name=$(echo "$var_name" | tr -d '\r\n')
        
        # Check if it matches our pattern
        if [[ "$var_name" =~ ^DATASET_.*_NAME$ ]]; then
            # Extract the middle part (between DATASET_ and _NAME)
            local key="${var_name#DATASET_}"
            key="${key%_NAME}"
            
            # Convert to lowercase for consistency
            key=$(echo "$key" | tr '[:upper:]' '[:lower:]')
            
            # Add to our result array
            dataset_keys+=("$key")
        fi
    done < <(set | cut -d= -f1)  # Get all defined variable names
    
    # Output the dataset keys
    for key in "${dataset_keys[@]}"; do
        echo "$key"
    done
}

# Count files in a GCS path
count_files() {
    local gcs_path="$1"
    local count=$(gcloud storage ls -r "$gcs_path" | wc -l)
    echo "$count files found at $gcs_path"
}

# --- Parse command ---
if [[ $# -lt 1 ]] || [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
    exit 0
fi

COMMAND="$1"
shift

# Validate command
case "$COMMAND" in
    download-local|upload|download-gcs|clean|list|count) ;; # Valid command
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
        --datasets)
            shift
            DATASETS=""
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                DATASETS="$DATASETS $1"
                shift
            done
            DATASETS="${DATASETS# }" # Remove leading space
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

# --- Setup ---
log_section "Setup"
setup_auth

# Extract just the path part after bucket name from BUCKET_DATRAIN
GCS_DATASETS_PATH=$(echo "$BUCKET_DATRAIN" | sed 's|gs://[^/]*/||')

# Ensure path ends with / (cursed counter = 2)
[[ "$GCS_DATASETS_PATH" != */ ]] && GCS_DATASETS_PATH="${GCS_DATASETS_PATH}/"

# Create output directory (use a relative path from the script directory)
mkdir -p "$SCRIPT_DIR/$OUTPUT_DIR"
OUTPUT_DIR="$SCRIPT_DIR/$OUTPUT_DIR"  # Update to full path for logging clarity
log "Using output directory: $OUTPUT_DIR"
log "Using GCS path: gs://$BUCKET_NAME/$GCS_DATASETS_PATH"


log_section "Parsing dataset keys from .env"
# Get dataset keys if not provided
if [[ -z "$DATASETS" ]]; then
    DATASETS=$(list_available_datasets)
    if [[ -z "$DATASETS" ]]; then
        log_error "No datasets found in environment variables (DATASET_*_NAME)"
        log_warning "Check your .env file to ensure it contains dataset definitions"
        exit 1
    fi
fi

# --- Execute command ---
log_section "Executing $COMMAND"
log "Configuration:"
log "- Output directory: $OUTPUT_DIR"
log "- Bucket name: $BUCKET_NAME"
log "- Datasets: ${DATASETS:-all}"

# Download datasets from Hugging Face to local storage
if [[ "$COMMAND" == "download-local" ]]; then
    log_section "Downloading Datasets from Hugging Face"
    
    for dataset_key in $DATASETS; do
        dataset_info=$(get_dataset_info "$dataset_key")
        dataset_name=$(echo "$dataset_info" | cut -d' ' -f2)
        
        if [[ -z "$dataset_name" ]]; then
            log_warning "Dataset $dataset_key not found in environment variables"
            continue
        fi
        
        log "Downloading $dataset_name dataset..."
        
        # Embedding minimalist .py script to download datasets from Hugging Face
        python << EOF
from datasets import load_dataset
import os
import sys

# Get current working directory - crucial for consistent path references
current_dir = os.getcwd()
dataset_name = '${dataset_name}'
# Create a purely relative path from the current directory
rel_path = os.path.join('${SCRIPT_DIR#$PROJECT_DIR/}', '${OUTPUT_DIR##*/}', '${dataset_key}')
output_path = os.path.normpath(os.path.join(current_dir, rel_path))

print(f'Loading dataset {dataset_name}...')
dataset = load_dataset(dataset_name)
print(f'Saving dataset to {output_path}...')
os.makedirs(output_path, exist_ok=True)  # Ensure the directory exists
dataset.save_to_disk(output_path)
print(f'Dataset successfully saved to {output_path}')
# List the directory contents to verify files were created
print('Files created:')
for root, dirs, files in os.walk(output_path):
    for file in files:
        print(f'  - {os.path.join(root, file)}')
EOF
        [[ $? -eq 0 ]] && log_success "Successfully downloaded $dataset_key dataset" || \
            log_error "Failed to download $dataset_key dataset"
    done

# Upload datasets from local storage to GCS bucket
elif [[ "$COMMAND" == "upload" ]]; then
    log_section "Uploading Datasets to GCS"
    
    for dataset_key in $DATASETS; do
        local_dataset_path="$OUTPUT_DIR/$dataset_key"
        gcs_dataset_path="gs://$BUCKET_NAME/$GCS_DATASETS_PATH$dataset_key"
        
        if [[ ! -d "$local_dataset_path" ]]; then
            log_warning "Dataset $dataset_key not found at $local_dataset_path"
            continue
        fi
        
        log "Uploading $dataset_key dataset to $gcs_dataset_path..."
        gcloud storage cp -r "$local_dataset_path/" "$gcs_dataset_path/" # Use recursive flag properly with directory path
        
        [[ $? -eq 0 ]] && log_success "Successfully uploaded $dataset_key dataset" || \
            log_error "Failed to upload $dataset_key dataset"
    done

# Download datasets from GCS bucket to local storage
elif [[ "$COMMAND" == "download-gcs" ]]; then
    log_section "Downloading Datasets from GCS"
    
    for dataset_key in $DATASETS; do
        local_dataset_path="$OUTPUT_DIR/$dataset_key"
        gcs_dataset_path="gs://$BUCKET_NAME/$GCS_DATASETS_PATH$dataset_key"
        
        # Check if the dataset exists in GCS
        if ! gcloud storage ls "$gcs_dataset_path" &>/dev/null; then
            log_warning "Dataset $dataset_key not found in bucket at $gcs_dataset_path"
            continue
        fi
        
        log "Downloading $dataset_key dataset from $gcs_dataset_path..."
        mkdir -p "$local_dataset_path"
        
        # Use recursive flag properly
        gcloud storage cp -r "$gcs_dataset_path/" "$local_dataset_path/"
        
        [[ $? -eq 0 ]] && log_success "Successfully downloaded $dataset_key dataset" || \
            log_error "Failed to download $dataset_key dataset"
    done

# Clean/remove datasets from GCS bucket
elif [[ "$COMMAND" == "clean" ]]; then
    log_section "Cleaning Datasets from GCS"
    
    # Single confirmation for all deletions
    delete_msg="${DATASETS:-all datasets} from gs://$BUCKET_NAME/$GCS_DATASETS_PATH"
    if ! confirm_delete "$delete_msg"; then
        log "Operation cancelled by user"
        exit 0
    fi
    
    for dataset_key in $DATASETS; do
        gcs_dataset_path="gs://$BUCKET_NAME/$GCS_DATASETS_PATH$dataset_key"
        
        # Check if the dataset exists before attempting to remove
        if ! gcloud storage ls "$gcs_dataset_path" &>/dev/null; then
            log_warning "Dataset $dataset_key not found in bucket at $gcs_dataset_path"
            continue
        fi
        
        log "Removing $dataset_key dataset from $gcs_dataset_path..."
        gcloud storage rm -r "$gcs_dataset_path/**"
        
        [[ $? -eq 0 ]] && log_success "Successfully removed $dataset_key dataset" || \
            log_error "Failed to remove $dataset_key dataset"
    done

# List all blobs/files in the GCS bucket
elif [[ "$COMMAND" == "list" ]]; then
    log_section "Listing Content in GCS Bucket"
    
    log "Listing all datasets in gs://$BUCKET_NAME/$GCS_DATASETS_PATH..."
    gcloud storage ls "gs://$BUCKET_NAME/$GCS_DATASETS_PATH"
    
    if [[ -n "$DATASETS" ]]; then
        for dataset_key in $DATASETS; do
            gcs_dataset_path="gs://$BUCKET_NAME/$GCS_DATASETS_PATH$dataset_key"
            
            # Check if the dataset exists before attempting to list
            if ! gcloud storage ls "$gcs_dataset_path" &>/dev/null; then
                log_warning "Dataset $dataset_key not found in bucket at $gcs_dataset_path"
                continue
            fi
            
            log_section "Contents of dataset: $dataset_key"
            gcloud storage ls -r "$gcs_dataset_path/**"
            echo ""
        done
    fi

# Count files in the GCS bucket datasets
elif [[ "$COMMAND" == "count" ]]; then
    log_section "Counting Files in GCS Bucket"
    
    log "Counting files in gs://$BUCKET_NAME/$GCS_DATASETS_PATH..."
    
    if [[ -n "$DATASETS" ]]; then
        for dataset_key in $DATASETS; do
            gcs_dataset_path="gs://$BUCKET_NAME/$GCS_DATASETS_PATH$dataset_key"
            
            # Check if the dataset exists before attempting to count
            if ! gcloud storage ls "$gcs_dataset_path" &>/dev/null; then
                log_warning "Dataset $dataset_key not found in bucket at $gcs_dataset_path"
                continue
            fi
            
            log_section "File count for dataset: $dataset_key"
            count_files "$gcs_dataset_path/**"
        done
    else
        # Count all datasets
        count_files "gs://$BUCKET_NAME/$GCS_DATASETS_PATH**"
    fi
fi

log_success "Command $COMMAND completed successfully!"
exit 0