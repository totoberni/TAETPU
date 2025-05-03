#!/bin/bash

# Script to set up the volume directory structure for TPU container

# --- Basic setup ---
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Import common functions ---
source "$PROJECT_DIR/infrastructure/utils/common.sh"

# Initialize script and set up paths
init_script "Volume Directory Setup"

# --- Load environment variables ---
ENV_FILE="$PROJECT_DIR/config/.env"
load_env_vars "$ENV_FILE"

log_section "Setting Up Volume Directories"

# --- Create directories if they don't exist ---
VOLUME_DIRS=(
  "${HOST_SRC_DIR:-/tmp/tae_src}"
  "${HOST_DATASETS_DIR:-$PROJECT_DIR/datasets}"
  "${HOST_MODELS_DIR:-$PROJECT_DIR/models}"
  "${HOST_CHECKPOINTS_DIR:-$PROJECT_DIR/checkpoints}"
  "${HOST_LOGS_DIR:-$PROJECT_DIR/logs}"
  "${HOST_RESULTS_DIR:-$PROJECT_DIR/results}"
)

for dir in "${VOLUME_DIRS[@]}"; do
  if [ ! -d "$dir" ]; then
    log "Creating directory: $dir"
    mkdir -p "$dir"
    chmod 777 "$dir"
  else
    log "Directory already exists: $dir"
  fi
done

# --- Create subdirectories for src if it doesn't exist ---
SRC_DIR="${HOST_SRC_DIR:-/tmp/tae_src}"
SRC_SUBDIRS=(
  "cache/prep"
  "configs"
  "data"
  "datasets/clean/static"
  "datasets/clean/transformer"
  "datasets/raw"
  "models/prep"
)

for subdir in "${SRC_SUBDIRS[@]}"; do
  if [ ! -d "$SRC_DIR/$subdir" ]; then
    log "Creating src subdirectory: $subdir"
    mkdir -p "$SRC_DIR/$subdir"
    chmod 777 "$SRC_DIR/$subdir"
  fi
done

# --- Create README files in each directory ---
for dir in "${VOLUME_DIRS[@]}"; do
  README_FILE="$dir/README.md"
  if [ ! -f "$README_FILE" ]; then
    log "Creating README file in $dir"
    
    # Extract the directory name for the title
    DIR_NAME=$(basename "$dir")
    
    # Create README content based on directory type
    case "$DIR_NAME" in
      "datasets"|*"dataset"*)
        cat > "$README_FILE" << EOF
# Datasets Directory

This directory contains input datasets for the Transformer Ablation Experiment.

## Structure
- \`raw/\`: Raw downloaded datasets before preprocessing
- \`clean/\`: Processed datasets ready for model consumption
  - \`transformer/\`: Datasets formatted for transformer models
  - \`static/\`: Datasets formatted for static embedding models

## Usage
Datasets are automatically mounted to the Docker container at \`/app/datasets\`.
EOF
        ;;
      
      "models"|*"model"*)
        cat > "$README_FILE" << EOF
# Models Directory

This directory contains model definitions and saved models for the Transformer Ablation Experiment.

## Structure
- \`prep/\`: Preprocessing models (tokenizers, etc.)
- \`transformer/\`: Transformer model implementations
- \`static/\`: Static embedding model implementations
- \`ablations/\`: Ablated model variants

## Usage
Models are automatically mounted to the Docker container at \`/app/models\`.
EOF
        ;;
      
      "checkpoints"|*"checkpoint"*)
        cat > "$README_FILE" << EOF
# Checkpoints Directory

This directory contains saved model checkpoints from training runs.

## Structure
Organized by experiment name and date:
- \`{experiment_name}/{date}/\`: Checkpoint files

## Usage
Checkpoints are automatically mounted to the Docker container at \`/app/checkpoints\`.
EOF
        ;;
      
      "logs"|*"log"*)
        cat > "$README_FILE" << EOF
# Logs Directory

This directory contains training and experiment logs.

## Structure
- \`train/\`: Training logs
- \`eval/\`: Evaluation logs
- \`tensorboard/\`: TensorBoard event files

## Usage
Logs are automatically mounted to the Docker container at \`/app/logs\`.
EOF
        ;;
      
      "results"|*"result"*)
        cat > "$README_FILE" << EOF
# Results Directory

This directory contains experiment results and analysis.

## Structure
- \`{experiment_name}/\`: Results organized by experiment
- \`plots/\`: Generated plots and visualizations
- \`tables/\`: Data tables and CSVs

## Usage
Results are automatically mounted to the Docker container at \`/app/results\`.
EOF
        ;;
      
      *)
        cat > "$README_FILE" << EOF
# $DIR_NAME Directory

This directory contains files for the Transformer Ablation Experiment.

## Usage
This directory is mounted to the Docker container at \`/app/${DIR_NAME,,}\`.
EOF
        ;;
    esac
    
    log_success "Created README file: $README_FILE"
  fi
done

# --- Check and create Docker volumes if needed ---
log_section "Setting Up Docker Volumes"

# Define standard volumes
DOCKER_VOLUMES=(
  "tae-datasets"
  "tae-models"
  "tae-checkpoints"
  "tae-logs"
  "tae-results"
)

for volume in "${DOCKER_VOLUMES[@]}"; do
  if ! docker volume ls -q | grep -q "^$volume$"; then
    log "Creating Docker volume: $volume"
    docker volume create "$volume"
    log_success "Created Docker volume: $volume"
  else
    log "Docker volume already exists: $volume"
  fi
done

log_success "Volume directories and Docker volumes setup complete"

# Make the script executable
chmod +x "$0"
exit 0 