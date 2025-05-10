#!/bin/bash
set -e

# Get the project directory (2 levels up from this script)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/../.." &> /dev/null && pwd )"
ENV_FILE="$PROJECT_DIR/config/.env"

# Source common utilities
source "$SCRIPT_DIR/../utils/common.sh"

# Initialize
init_script 'Sync Files with Container'

# Load environment variables from .env file
load_env_vars "$ENV_FILE" || exit 1

# Check required environment variables
check_env_vars "PROJECT_ID" "TPU_NAME" "TPU_ZONE" "CONTAINER_NAME" || exit 1

# Define common variables
function define_variables() {
    # Set container paths
    CONTAINER_MOUNT_DIR="${CONTAINER_MOUNT_DIR:-/app/mount}"
    HOST_MOUNT_DIR="${HOST_MOUNT_DIR:-mount}"
    LOCAL_SRC_DIR="./src"
    
    # Flags
    IS_ALL=false
    TARGET_PATH=""
    IS_DRY_RUN=false
    IS_VERBOSE=false
    
    # Temp directories
    LOCAL_TEMP_DIR=""
    MANIFEST_DIR=""
}

# Display help message
function display_help() {
    echo "Usage: $0 [--all] [--dry-run] [--verbose] [path/to/file_or_dir]"
    echo ""
    echo "Options:"
    echo "  --all: Sync all files in the src directory"
    echo "  --dry-run: Show what would be updated without making changes"
    echo "  --verbose: Show detailed information about file comparison"
    echo "  path/to/file_or_dir: Specific file or directory to sync"
    echo ""
    echo "Examples:"
    echo "  $0 --all                 # Sync entire src directory"
    echo "  $0 --dry-run --all       # Show what would be synced without changes"
    echo "  $0 example.py            # Sync a specific file"
    echo "  $0 src/data              # Sync a specific directory"
}

# Parse command-line arguments
function parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --all)
                IS_ALL=true
                shift
                ;;
            --dry-run)
                IS_DRY_RUN=true
                shift
                ;;
            --verbose)
                IS_VERBOSE=true
                shift
                ;;
            -h|--help)
                display_help
                exit 0
                ;;
            *)
                TARGET_PATH="$1"
                shift
                ;;
        esac
    done
    
    # Validate arguments
    if [ "$IS_ALL" = false ] && [ -z "$TARGET_PATH" ]; then
        log_error "No target path specified. Use --all or provide a specific path."
        display_help
        exit 1
    fi
}

# Initialize temporary directories
function setup_temp_dirs() {
    LOCAL_TEMP_DIR=$(mktemp -d)
    MANIFEST_DIR=$(mktemp -d)
    trap "rm -rf $LOCAL_TEMP_DIR $MANIFEST_DIR" EXIT
    
    # Create output directories
    if [ "$IS_ALL" = true ]; then
        # For --all, create a proper src subdirectory structure
        mkdir -p "$LOCAL_TEMP_DIR/src"
    else
        mkdir -p "$LOCAL_TEMP_DIR"
    fi
    
    mkdir -p "$LOCAL_TEMP_DIR/delete"
}

# Check connectivity to TPU VM and Docker container
function check_connectivity() {
    # Check if TPU VM is accessible
    log "Checking TPU VM connection (project: ${PROJECT_ID}, zone: ${TPU_ZONE}, TPU: ${TPU_NAME})..."
    vmssh "echo 'TPU VM connection successful'" || { 
        log_error "Failed to connect to TPU VM. Check your configuration."
        exit 1
    }
    
    # Check if Docker container is running
    log "Checking Docker container status (${CONTAINER_NAME})..."
    vmssh "sudo docker ps | grep -q ${CONTAINER_NAME}" || { 
        log_error "Container ${CONTAINER_NAME} is not running on TPU VM."
        exit 1
    }
}

# Generate list of local files to check
function generate_local_manifest() {
    log "Generating local file manifest..."
    
    if [ "$IS_ALL" = true ]; then
        # List all files in src directory
        if [ -d "$LOCAL_SRC_DIR" ]; then
            find "$LOCAL_SRC_DIR" -type f -not -path "*/\.*" | sort > "$MANIFEST_DIR/local_files.txt"
        else
            log_error "Local ./src directory not found"
            exit 1
        fi
    else
        # Handle specific file or directory
        if [ -d "$TARGET_PATH" ]; then
            # It's a directory
            find "$TARGET_PATH" -type f -not -path "*/\.*" | sort > "$MANIFEST_DIR/local_files.txt"
        elif [ -f "$TARGET_PATH" ]; then
            # It's a file
            echo "$TARGET_PATH" > "$MANIFEST_DIR/local_files.txt"
        else
            log_error "Target path does not exist: $TARGET_PATH"
            exit 1
        fi
    fi
    
    # Get file count
    FILE_COUNT=$(wc -l < "$MANIFEST_DIR/local_files.txt")
    log "Found $FILE_COUNT local files to check"
}

# Get list of files in the container
function get_container_manifest() {
    log "Retrieving container file manifest..."
    
    # Command to list all files in container
    local list_cmd="sudo docker exec ${CONTAINER_NAME} find ${CONTAINER_MOUNT_DIR}/src -type f 2>/dev/null | sort > /tmp/container_files.txt || echo 'No files found in container src directory'"
    vmssh "$list_cmd" || { 
        log_warning "Failed to get container file list"
        echo "" > "$MANIFEST_DIR/container_files.txt"
        return 1
    }
    
    # Copy the container file manifest to local machine
    vmscp "${TPU_NAME}:/tmp/container_files.txt" "$MANIFEST_DIR/container_files.txt" || {
        log_warning "Failed to copy container file list"
        echo "" > "$MANIFEST_DIR/container_files.txt"
        return 1
    }
    
    return 0
}

# Find files to delete (in container but not in local)
function find_files_to_delete() {
    if [ "$IS_ALL" != true ]; then
        return 0  # Only delete files when using --all flag
    fi
    
    log "Checking for files to delete..."
    
    # Create a list of normalized local paths for comparison
    cat "$MANIFEST_DIR/local_files.txt" | sed "s|^./src/||g" | sort > "$MANIFEST_DIR/local_normalized.txt"
    
    # Create a list of normalized container paths for comparison
    cat "$MANIFEST_DIR/container_files.txt" | sed "s|^${CONTAINER_MOUNT_DIR}/src/||g" | sort > "$MANIFEST_DIR/container_normalized.txt"
    
    # Find files to delete (in container but not local)
    comm -23 "$MANIFEST_DIR/container_normalized.txt" "$MANIFEST_DIR/local_normalized.txt" > "$MANIFEST_DIR/files_to_delete.txt"
    
    # Count files to delete
    DELETE_COUNT=$(wc -l < "$MANIFEST_DIR/files_to_delete.txt")
    if [ "$DELETE_COUNT" -gt 0 ]; then
        log "Found $DELETE_COUNT files to delete"
        
        # If in dry run mode, just show what would be deleted
        if [ "$IS_DRY_RUN" = true ]; then
            log "DRY RUN - The following files would be deleted:"
            cat "$MANIFEST_DIR/files_to_delete.txt"
        else
            # Create a deletion script to run on the container
            echo "#!/bin/bash" > "$LOCAL_TEMP_DIR/delete_script.sh"
            echo "# Auto-generated file deletion script" >> "$LOCAL_TEMP_DIR/delete_script.sh"
            
            while IFS= read -r REL_PATH; do
                [ -z "$REL_PATH" ] && continue
                CONTAINER_PATH="${CONTAINER_MOUNT_DIR}/src/${REL_PATH}"
                echo "rm -f \"$CONTAINER_PATH\"" >> "$LOCAL_TEMP_DIR/delete_script.sh"
                if [ "$IS_VERBOSE" = true ]; then
                    log "Will delete: $CONTAINER_PATH"
                fi
            done < "$MANIFEST_DIR/files_to_delete.txt"
            
            # Make script executable
            chmod +x "$LOCAL_TEMP_DIR/delete_script.sh"
        fi
    else
        log "No files need to be deleted"
    fi
    
    # Return file count for later use
    echo "$DELETE_COUNT"
}

# Find files to update (local files different from container)
function find_files_to_update() {
    local needs_update=false
    
    log "Comparing local and container files..."
    
    # Read local file manifest and check each file
    while IFS= read -r LOCAL_FILE; do
        # Skip empty lines
        [ -z "$LOCAL_FILE" ] && continue
        
        # Calculate the corresponding container path
        if [[ "$LOCAL_FILE" == "./src/"* ]]; then
            # Handle paths that already include ./src/
            CONTAINER_FILE="${CONTAINER_MOUNT_DIR}${LOCAL_FILE#.}"
            # Keep src/ prefix in RELATIVE_PATH for proper directory structure
            RELATIVE_PATH="${LOCAL_FILE#./}"
        else
            # Handle paths that don't include ./src/
            CONTAINER_FILE="${CONTAINER_MOUNT_DIR}/src/${LOCAL_FILE#./src/}"
            
            # Ensure the relative path includes src/ prefix
            if [[ "$LOCAL_FILE" == "./src"* ]]; then
                RELATIVE_PATH="${LOCAL_FILE#./}"
            else
                # If we're processing a specific file/dir not under src/, add src/ prefix
                RELATIVE_PATH="src/${LOCAL_FILE#./}"
            fi
        fi
        
        # Normalize paths to find in container_files.txt
        CONTAINER_PATH_NORMALIZED=$(echo "$CONTAINER_FILE" | sed 's/\/\//\//g')
        
        # Check if the file exists in the container
        if grep -q "$CONTAINER_PATH_NORMALIZED" "$MANIFEST_DIR/container_files.txt"; then
            if [ "$IS_VERBOSE" = true ]; then
                log "Found in container: $CONTAINER_PATH_NORMALIZED"
            fi
            
            # File exists in both local and container, check if we need to update
            # Since we can't easily compare timestamps between systems, add file to update list
            TARGET_DIR=$(dirname "$LOCAL_TEMP_DIR/$RELATIVE_PATH")
            mkdir -p "$TARGET_DIR"
            cp "$LOCAL_FILE" "$TARGET_DIR/"
            needs_update=true
        else
            # File doesn't exist in container, always add to update list
            if [ "$IS_VERBOSE" = true ]; then
                log "New file: $LOCAL_FILE"
            fi
            TARGET_DIR=$(dirname "$LOCAL_TEMP_DIR/$RELATIVE_PATH")
            mkdir -p "$TARGET_DIR"
            cp "$LOCAL_FILE" "$TARGET_DIR/"
            needs_update=true
        fi
    done < "$MANIFEST_DIR/local_files.txt"
    
    # Check if we found any files that need updating
    if [ "$needs_update" = false ]; then
        log_warning "No files need to be updated"
        return 1
    fi
    
    # Count files to update
    UPDATE_COUNT=$(find "$LOCAL_TEMP_DIR" -type f -not -path "*/delete/*" | wc -l)
    log "Found $UPDATE_COUNT files to update"
    
    # In dry run mode, just show what would be updated and exit
    if [ "$IS_DRY_RUN" = true ]; then
        log "DRY RUN - The following files would be updated:"
        find "$LOCAL_TEMP_DIR" -type f -not -path "*/delete/*" | sort
        log_success "Dry run completed. No files were modified."
        return 1
    fi
    
    # Return update count for later use
    echo "$UPDATE_COUNT"
}

# Execute deletion of files in container
function execute_deletions() {
    local delete_count=$1
    
    if [ "$IS_ALL" != true ] || [ ! -f "$LOCAL_TEMP_DIR/delete_script.sh" ] || [ "$delete_count" -le 0 ]; then
        return 0
    fi
    
    log "Deleting $delete_count files that don't exist locally..."
    
    # Transfer the deletion script to the TPU VM
    vmscp "${LOCAL_TEMP_DIR}/delete_script.sh" "${TPU_NAME}:${HOST_MOUNT_DIR}/" || {
        log_error "Failed to transfer deletion script to TPU VM"
        return 1
    }
    
    # Execute the deletion script in the container
    local delete_cmd="
        chmod +x ${HOST_MOUNT_DIR}/delete_script.sh
        sudo docker cp ${HOST_MOUNT_DIR}/delete_script.sh ${CONTAINER_NAME}:/tmp/delete_script.sh
        sudo docker exec ${CONTAINER_NAME} chmod +x /tmp/delete_script.sh
        sudo docker exec ${CONTAINER_NAME} /tmp/delete_script.sh
        sudo docker exec ${CONTAINER_NAME} rm /tmp/delete_script.sh
        rm ${HOST_MOUNT_DIR}/delete_script.sh
    "
    
    vmssh "$delete_cmd" || {
        log_error "Failed to execute deletion script in container"
        return 1
    }
    
    log_success "File deletion completed"
    return 0
}

# Update files in container
function update_container_files() {
    local update_count=$1
    
    # Create a tar file of the files to update
    TAR_FILE="${LOCAL_TEMP_DIR}/update.tar"
    tar -cf "${TAR_FILE}" -C "${LOCAL_TEMP_DIR}" $(ls -A "${LOCAL_TEMP_DIR}" | grep -v "delete") || {
        log_error "Failed to create tar file of updated files"
        return 1
    }
    
    # Transfer the tar file to TPU VM
    log "Transferring updated files to TPU VM..."
    vmscp "${TAR_FILE}" "${TPU_NAME}:${HOST_MOUNT_DIR}/" || {
        log_error "Failed to transfer update tar to TPU VM"
        return 1
    }
    
    # Extract the tar file on the TPU VM and copy to container
    log "Updating files in Docker container..."
    local update_cmd="
        # Extract the tar file on the VM
        cd ${HOST_MOUNT_DIR} && tar -xf update.tar && rm update.tar
        
        # Create target directory structure in container if needed
        sudo docker exec ${CONTAINER_NAME} mkdir -p ${CONTAINER_MOUNT_DIR}
        
        # Copy files from VM to container with proper path preservation
        if [ -d \"${HOST_MOUNT_DIR}/src\" ]; then
            # If there's a src directory in the extracted tar, copy it to maintain isometry
            sudo docker cp ${HOST_MOUNT_DIR}/src ${CONTAINER_NAME}:${CONTAINER_MOUNT_DIR}/
        else
            # If no src directory was extracted (specific file/dir sync), determine appropriate path
            if [ \"$IS_ALL\" = true ]; then
                # Should have src directory, something went wrong
                echo 'Warning: Expected src directory not found in extracted files'
                # Copy everything to src as fallback
                sudo docker exec ${CONTAINER_NAME} mkdir -p ${CONTAINER_MOUNT_DIR}/src
                sudo docker cp ${HOST_MOUNT_DIR}/. ${CONTAINER_NAME}:${CONTAINER_MOUNT_DIR}/src/
            else
                # For specific files/dirs not under src/, determine target path
                RELATIVE_PATH=\"$(basename \"$TARGET_PATH\")\"
                if [[ \"$TARGET_PATH\" == *\"/src/\"* || \"$TARGET_PATH\" == \"src/\"* ]]; then
                    # Target is within src/ directory, extract the path after src/
                    SUBPATH=\"$(echo \"$TARGET_PATH\" | sed -n 's/.*src\///p')\"
                    if [ -n \"\$SUBPATH\" ]; then
                        # Copy to the appropriate subdirectory under src/
                        sudo docker exec ${CONTAINER_NAME} mkdir -p ${CONTAINER_MOUNT_DIR}/src/\$(dirname \"\$SUBPATH\")
                        sudo docker cp ${HOST_MOUNT_DIR}/\$(basename \"\$SUBPATH\") ${CONTAINER_NAME}:${CONTAINER_MOUNT_DIR}/src/\$(dirname \"\$SUBPATH\")/
                    else
                        # Copy directly to src/
                        sudo docker cp ${HOST_MOUNT_DIR}/. ${CONTAINER_NAME}:${CONTAINER_MOUNT_DIR}/src/
                    fi
                else
                    # Copy to src/ by default
                    sudo docker exec ${CONTAINER_NAME} mkdir -p ${CONTAINER_MOUNT_DIR}/src
                    sudo docker cp ${HOST_MOUNT_DIR}/. ${CONTAINER_NAME}:${CONTAINER_MOUNT_DIR}/src/
                fi
            fi
        fi
        
        # Set proper permissions
        sudo docker exec ${CONTAINER_NAME} chmod -R 777 ${CONTAINER_MOUNT_DIR}/src
    "
    
    vmssh "$update_cmd" || {
        log_error "Failed to update files in container"
        return 1
    }
    
    return 0
}

# Report sync results
function report_results() {
    local update_count=$1
    local delete_count=$2
    
    # Final log and container inspection
    if [ "$IS_ALL" = true ] && [ "$delete_count" -gt 0 ]; then
        log_success "Successfully synced $update_count files and deleted $delete_count files in container"
    else
        log_success "Successfully synced $update_count files to container"
    fi
    
    # Optionally show the updated files in the container
    if [ "$IS_VERBOSE" = true ]; then
        log "Updated files in container:"
        vmssh "echo 'Container contents after sync:'; sudo docker exec ${CONTAINER_NAME} find ${CONTAINER_MOUNT_DIR}/src -type f | sort"
    fi
}

# Main function to orchestrate sync process
function main() {
    define_variables
    parse_arguments "$@"
    setup_temp_dirs
    check_connectivity
    generate_local_manifest
    get_container_manifest
    
    # Process files
    delete_count=$(find_files_to_delete)
    update_count=$(find_files_to_update)
    
    # Exit if dry run or no updates needed
    if [ "$IS_DRY_RUN" = true ] || [ -z "$update_count" ]; then
        log_success "No changes made to container"
        exit 0
    fi
    
    # Execute syncing
    execute_deletions "$delete_count"
    update_container_files "$update_count" && report_results "$update_count" "$delete_count"
}

# Run main function
main "$@"
exit $? 