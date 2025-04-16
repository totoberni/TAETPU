#!/bin/bash

# --- Get script directory for absolute path references ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/infrastructure/utils/common.sh"
load_env_vars "$PROJECT_DIR/config/.env"

# --- Default values ---
OUTPUT_DIR="./tools/gcs_ops/downloads"  # Use a simple relative path
DATASETS=""
GCSFUSE_FLAGS="--implicit-dirs"  # Default flags for gcsfuse
UPLOAD_TYPE=""
FILES_TO_UPLOAD=""
DIR_TO_UPLOAD=""

# --- Functions ---
show_help() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  download       Download datasets (use --gcs or --local)"
    echo "  upload         Upload datasets from local storage to GCS bucket"
    echo "  clean          Remove datasets from GCS bucket"
    echo "  list           List all blobs/files in the GCS bucket"
    echo "  fuse-vm        Mount GCS bucket on TPU VM using FUSE"
    echo "  unfuse-vm      Unmount GCS bucket from TPU VM"
    echo ""
    echo "Options:"
    echo "  --output-dir DIR    Directory to save datasets (default: $OUTPUT_DIR)"
    echo "  --datasets LIST     Space-separated list of dataset keys to process"
    echo "  --gcs               Download from GCS bucket (for download command)"
    echo "  --local             Download from Hugging Face (for download command)"
    echo "  --files PATHS       Space-separated list of files to upload"
    echo "  --dir PATH          Directory to upload recursively"
    echo "  --fuse-flags FLAGS  Flags to pass to gcsfuse (default: --implicit-dirs)"
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

# List all available datasets from environment variables in a Windows Git Bash compatible way
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

# Mount GCS bucket directories on TPU VM using FUSE
mount_gcs_bucket() {
    local container_name="eu.gcr.io/${PROJECT_ID}/tae-tpu:v1"

    # Check if TPU VM exists and is accessible
    log "Checking if TPU VM '$TPU_NAME' exists and is accessible..."
    if ! gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" &> /dev/null; then
        log_error "TPU VM '$TPU_NAME' does not exist or is not accessible"
        return 1
    fi

    # Create a script to execute on the TPU VM
    local tmp_script=$(mktemp)
    cat > "$tmp_script" << EOF
#!/bin/bash
# Mount GCS bucket with FUSE
echo "Mounting GCS bucket directories to container..."

# # Check if the container is running
# if ! gcloud container images list-tags "$container_name" &> /dev/null; then 
#     echo "Container '$container_name' is not running"
#     exit 1
# fi

# Mount exp directory (includes datasets and all experiment data)
echo "Mounting exp/ directory..."
sudo docker exec $container_name bash -c "export BUCKET_NAME=$BUCKET_NAME && export GCSFUSE_FLAGS='$GCSFUSE_FLAGS' && gcsfuse \$GCSFUSE_FLAGS --only-dir exp \$BUCKET_NAME /app/gcs_mount/exp"
if [ \$? -ne 0 ]; then
    echo "Failed to mount exp/ directory"
    exit 1
fi

# Mount logs directory
echo "Mounting logs directory..."
sudo docker exec $container_name bash -c "export BUCKET_NAME=$BUCKET_NAME && export GCSFUSE_FLAGS='$GCSFUSE_FLAGS' && gcsfuse \$GCSFUSE_FLAGS --only-dir logs \$BUCKET_NAME /app/gcs_mount/logs"
if [ \$? -ne 0 ]; then
    echo "Failed to mount logs directory"
    exit 1
fi

echo "Successfully mounted GCS bucket directories to container"
EOF

    chmod +x "$tmp_script"

    # Upload and execute the script on the TPU VM
    log "Mounting GCS bucket directories on TPU VM..."
    gcloud compute tpus tpu-vm scp "$tmp_script" "$TPU_NAME:/tmp/mount_bucket.sh" --zone="$TPU_ZONE"
    gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="bash /tmp/mount_bucket.sh && rm /tmp/mount_bucket.sh"
    
    rm "$tmp_script"
    
    log_success "GCS bucket mounting command sent to TPU VM"
}

# Unmount GCS bucket from TPU VM
unmount_gcs_bucket() {
    local container_name= "eu.gcr.io/${PROJECT_ID}/tae-tpu:v1"
    
    # Check if TPU VM exists and is accessible
    log "Checking if TPU VM '$TPU_NAME' exists and is accessible..."
    if ! gcloud compute tpus tpu-vm describe "$TPU_NAME" --zone="$TPU_ZONE" &> /dev/null; then
        log_error "TPU VM '$TPU_NAME' does not exist or is not accessible"
        return 1
    fi
    
    # Create a script to execute on the TPU VM
    local tmp_script=$(mktemp)
    cat > "$tmp_script" << EOF
#!/bin/bash
# Unmount the GCS bucket directories from the Docker container
echo "Unmounting GCS bucket directories from container..."

# # Check if the container is running
# if ! sudo docker run '$container_name' &> /dev/null; then 
#     echo "Container '$container_name' is not running"
#     exit 1
# fi

# Check and unmount exp directory
if sudo docker exec $container_name mountpoint -q /app/gcs_mount/exp; then
    echo "Unmounting /app/gcs_mount/exp..."
    sudo docker exec $container_name fusermount -u /app/gcs_mount/exp
    echo "Successfully unmounted /app/gcs_mount/exp"
else
    echo "/app/gcs_mount/exp is not mounted"
fi

# Check and unmount logs
if sudo docker exec $container_name mountpoint -q /app/gcs_mount/logs; then
    echo "Unmounting /app/gcs_mount/logs..."
    sudo docker exec $container_name fusermount -u /app/gcs_mount/logs
    echo "Successfully unmounted /app/gcs_mount/logs"
else
    echo "/app/gcs_mount/logs is not mounted"
fi
EOF

    chmod +x "$tmp_script"
    
    # Upload and execute the script on the TPU VM
    log "Unmounting GCS bucket from TPU VM..."
    gcloud compute tpus tpu-vm scp "$tmp_script" "$TPU_NAME:/tmp/unmount_bucket.sh" --zone="$TPU_ZONE"
    gcloud compute tpus tpu-vm ssh "$TPU_NAME" --zone="$TPU_ZONE" --command="bash /tmp/unmount_bucket.sh && rm /tmp/unmount_bucket.sh"
    
    rm "$tmp_script"
    
    log_success "GCS bucket unmounting command sent to TPU VM"
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
    download|upload|clean|list|fuse-vm|unfuse-vm) ;; # Valid command
    *)
        echo "Error: Unknown command '$COMMAND'"
        show_help
        exit 1
        ;;
esac

# Initialize download type
DOWNLOAD_TYPE=""

# --- Parse options ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --datasets)
            UPLOAD_TYPE="datasets"
            shift
            DATASETS=""
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                DATASETS="$DATASETS $1"
                shift
            done
            DATASETS="${DATASETS# }" # Remove leading space
            ;;
        --files)
            UPLOAD_TYPE="files"
            shift
            FILES_TO_UPLOAD=""
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do
                FILES_TO_UPLOAD="$FILES_TO_UPLOAD $1"
                shift
            done
            FILES_TO_UPLOAD="${FILES_TO_UPLOAD# }" # Remove leading space
            ;;
        --dir)
            UPLOAD_TYPE="dir"
            DIR_TO_UPLOAD="$2"
            shift 2
            ;;
        --fuse-flags)
            GCSFUSE_FLAGS="$2"
            shift 2
            ;;
        --gcs)
            DOWNLOAD_TYPE="gcs"
            shift
            ;;
        --local)
            DOWNLOAD_TYPE="local"
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

# --- Setup ---
log_section "Setup"
setup_auth

# Extract just the path part after bucket name from BUCKET_DATRAIN
GCS_DATASETS_PATH=$(echo "$BUCKET_DATRAIN" | sed 's|gs://[^/]*/||')

# Ensure path ends with /
[[ "$GCS_DATASETS_PATH" != */ ]] && GCS_DATASETS_PATH="${GCS_DATASETS_PATH}/"

# Create main output directory if it doesn't exist
if [[ ! -d "$OUTPUT_DIR" ]]; then
    mkdir -p "$OUTPUT_DIR"
    log "Created output directory: $OUTPUT_DIR"
fi

# Define download subdirectories
DOWNLOAD_LOCAL="$OUTPUT_DIR"
DOWNLOAD_GCS="$OUTPUT_DIR/gcs"

log "Using output directory: $OUTPUT_DIR"
log "Using GCS path: gs://$BUCKET_NAME/$GCS_DATASETS_PATH"

log_section "Parsing dataset keys from .env"
# Get dataset keys if not provided
if [[ -z "$DATASETS" && "$UPLOAD_TYPE" == "datasets" ]]; then
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
log "- Bucket name: $BUCKET_NAME"
log "- Datasets: ${DATASETS:-all}"

# Download datasets command (merged download-local and download-gcs)
if [[ "$COMMAND" == "download" ]]; then
    # Check if download type is specified
    if [[ -z "$DOWNLOAD_TYPE" ]]; then
        log_error "Download type not specified. Use --gcs or --local"
        exit 1
    fi
    
    if [[ "$DOWNLOAD_TYPE" == "local" ]]; then
        log_section "Downloading Datasets from Hugging Face"
        
        # Create local downloads directory if it doesn't exist
        if [[ ! -d "$DOWNLOAD_LOCAL" ]]; then
            mkdir -p "$DOWNLOAD_LOCAL"
            log "Created directory for local downloads: $DOWNLOAD_LOCAL"
        fi
        
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

dataset_name = '${dataset_name}'
output_path = os.path.join('${DOWNLOAD_LOCAL}', '${dataset_key}')

print(f'Loading dataset {dataset_name}...')
dataset = load_dataset(dataset_name)
print(f'Saving dataset to {output_path}...')
os.makedirs(output_path, exist_ok=True)
dataset.save_to_disk(output_path)
print(f'Dataset successfully saved to {output_path}')
EOF
            [[ $? -eq 0 ]] && log_success "Successfully downloaded $dataset_key dataset" || \
                log_error "Failed to download $dataset_key dataset"
        done
    elif [[ "$DOWNLOAD_TYPE" == "gcs" ]]; then
        log_section "Downloading Datasets from GCS"
        
        # Create GCS downloads directory if it doesn't exist
        if [[ ! -d "$DOWNLOAD_GCS" ]]; then
            mkdir -p "$DOWNLOAD_GCS"
            log "Created directory for GCS downloads: $DOWNLOAD_GCS"
        fi
        
        for dataset_key in $DATASETS; do
            local_dataset_path="$DOWNLOAD_GCS/$dataset_key"
            gcs_dataset_path="gs://$BUCKET_NAME/$GCS_DATASETS_PATH$dataset_key"
            
            # Check if the dataset exists in GCS
            if ! gcloud storage ls "$gcs_dataset_path" &>/dev/null; then
                log_warning "Dataset $dataset_key not found in bucket at $gcs_dataset_path"
                continue
            fi
            
            log "Downloading $dataset_key dataset from $gcs_dataset_path..."
            mkdir -p "$local_dataset_path"
            
            # Use recursive flag
            gcloud storage cp -r "$gcs_dataset_path/" "$local_dataset_path/"
            
            [[ $? -eq 0 ]] && log_success "Successfully downloaded $dataset_key dataset" || \
                log_error "Failed to download $dataset_key dataset"
        done
    fi

# Upload datasets from local storage to GCS bucket
elif [[ "$COMMAND" == "upload" ]]; then
    log_section "Uploading to GCS"
    
    # No upload type specified
    if [[ -z "$UPLOAD_TYPE" ]]; then
        log_error "Upload type not specified. Use --datasets, --files, or --dir"
        exit 1
    fi
    
    # Upload datasets (from .env)
    if [[ "$UPLOAD_TYPE" == "datasets" ]]; then
        log_section "Uploading Datasets to GCS"
        
        # Ensure datasets directory exists in bucket
        gcs_datasets_dir="gs://$BUCKET_NAME/${GCS_DATASETS_PATH}datasets"
        log "Ensuring datasets directory exists: $gcs_datasets_dir"
        
        # Create directory if it doesn't exist
        if ! gcloud storage ls "$gcs_datasets_dir" &>/dev/null; then
            touch /tmp/placeholder.txt
            gcloud storage cp /tmp/placeholder.txt "$gcs_datasets_dir/placeholder.txt"
            gcloud storage rm "$gcs_datasets_dir/placeholder.txt"
            rm /tmp/placeholder.txt
        fi
        
        for dataset_key in $DATASETS; do
            # Try to find dataset in local downloads first
            if [[ -d "$DOWNLOAD_LOCAL/$dataset_key" ]]; then
                local_dataset_path="$DOWNLOAD_LOCAL/$dataset_key"
            # Then check GCS downloads
            elif [[ -d "$DOWNLOAD_GCS/$dataset_key" ]]; then
                local_dataset_path="$DOWNLOAD_GCS/$dataset_key"
            else
                log_warning "Dataset $dataset_key not found in any local directory"
                continue
            fi
            
            # Upload to the specified path structure: gs://<BUCKET>/exp/datasets/<dataset_key>
            gcs_dataset_path="gs://$BUCKET_NAME/${GCS_DATASETS_PATH}datasets/$dataset_key"
            
            log "Uploading $dataset_key dataset to $gcs_dataset_path..."
            gcloud storage cp -r "$local_dataset_path/" "$gcs_dataset_path/"
            
            [[ $? -eq 0 ]] && log_success "Successfully uploaded $dataset_key dataset" || \
                log_error "Failed to upload $dataset_key dataset"
        done
    
    # Upload specific files
    elif [[ "$UPLOAD_TYPE" == "files" ]]; then
        log_section "Uploading Files to GCS"
        
        if [[ -z "$FILES_TO_UPLOAD" ]]; then
            log_error "No files specified for upload"
            exit 1
        fi
        
        for file in $FILES_TO_UPLOAD; do
            if [[ ! -f "$file" ]]; then
                log_warning "File not found: $file"
                continue
            fi
            
            filename=$(basename "$file")
            gcs_file_path="gs://$BUCKET_NAME/${GCS_DATASETS_PATH}downloads/$filename"
            
            log "Uploading file $file to $gcs_file_path..."
            gcloud storage cp "$file" "$gcs_file_path"
            
            [[ $? -eq 0 ]] && log_success "Successfully uploaded file: $filename" || \
                log_error "Failed to upload file: $filename"
        done
    
    # Upload directory recursively
    elif [[ "$UPLOAD_TYPE" == "dir" ]]; then
        log_section "Uploading Directory to GCS"
        
        if [[ -z "$DIR_TO_UPLOAD" ]]; then
            log_error "No directory specified for upload"
            exit 1
        fi
        
        if [[ ! -d "$DIR_TO_UPLOAD" ]]; then
            log_error "Directory not found: $DIR_TO_UPLOAD"
            exit 1
        fi
        
        dir_name=$(basename "$DIR_TO_UPLOAD")
        gcs_dir_path="gs://$BUCKET_NAME/${GCS_DATASETS_PATH}downloads/$dir_name"
        
        log "Uploading directory $DIR_TO_UPLOAD to $gcs_dir_path..."
        gcloud storage cp -r "$DIR_TO_UPLOAD/" "$gcs_dir_path/"
        
        [[ $? -eq 0 ]] && log_success "Successfully uploaded directory: $dir_name" || \
            log_error "Failed to upload directory: $dir_name"
    fi

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
    
    log "Listing all contents in gs://$BUCKET_NAME/..."
    gcloud storage ls "gs://$BUCKET_NAME/"
    
    # If datasets are specified, list them in detail
    if [[ -n "$DATASETS" ]]; then
        log_section "Listing Specific Datasets"
        
        for dataset_key in $DATASETS; do
            gcs_dataset_path="gs://$BUCKET_NAME/${GCS_DATASETS_PATH}datasets/$dataset_key"
            
            # Check if the dataset exists before attempting to list
            if ! gcloud storage ls "$gcs_dataset_path" &>/dev/null; then
                log_warning "Dataset $dataset_key not found in bucket at $gcs_dataset_path"
                continue
            fi
            
            log_section "Contents of dataset: $dataset_key"
            gcloud storage ls -r "$gcs_dataset_path/**"
            echo ""
        done
    # Otherwise, list all top-level directories recursively 
    else
        log_section "Bucket Structure Overview"
        
        # Get the top-level directories
        top_dirs=$(gcloud storage ls "gs://$BUCKET_NAME/" | tr -d '/' | xargs -n1 basename 2>/dev/null)
        
        for dir in $top_dirs; do
            # Skip empty results
            if [[ -z "$dir" ]]; then
                continue
            fi
            
            log_section "Contents of /$dir/"
            gcloud storage ls "gs://$BUCKET_NAME/$dir/"
            echo ""
        done
    fi

# Mount GCS bucket on TPU VM using FUSE
elif [[ "$COMMAND" == "fuse-vm" ]]; then
    log_section "Mounting GCS Bucket on TPU VM"
    
    # Check required environment variables
    check_env_vars "TPU_NAME" "TPU_ZONE" "BUCKET_NAME" || exit 1
    
    log "Configuration:"
    log "- TPU VM: $TPU_NAME (zone: $TPU_ZONE)"
    log "- Bucket: $BUCKET_NAME"
    log "- Mount directories: exp/ and logs/"
    log "- FUSE flags: $GCSFUSE_FLAGS"
    
    # Mount the bucket directories on the TPU VM
    mount_gcs_bucket
    
    log_success "GCS bucket mounting operation completed"

# Unmount GCS bucket from TPU VM
elif [[ "$COMMAND" == "unfuse-vm" ]]; then
    log_section "Unmounting GCS Bucket from TPU VM"
    
    # Check required environment variables
    check_env_vars "TPU_NAME" "TPU_ZONE" || exit 1
    
    log "Configuration:"
    log "- TPU VM: $TPU_NAME (zone: $TPU_ZONE)"
    log "- Mount directories: exp/ and logs/"
    
    # Unmount the bucket directories from the TPU VM
    unmount_gcs_bucket
    
    log_success "GCS bucket unmounting operation completed"
fi

log_success "Command $COMMAND completed successfully!"
exit 0