# Use official TensorFlow 2.18.0 image as base
FROM tensorflow/tensorflow:2.18.0

# Set working directory
WORKDIR /app

# Set environment variables for TPU support (these can be overridden via .env)
ENV TF_CPP_MIN_LOG_LEVEL=0 \
    PYTHONUNBUFFERED=1 \
    LD_LIBRARY_PATH=/usr/local/lib \
    PJRT_DEVICE=TPU \
    NEXT_PLUGGABLE_DEVICE_USE_C_API=true \
    TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so \
    TPU_NAME=local \
    TPU_LOAD_LIBRARY=0 \
    XLA_USE_BF16=1

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    curl \
    wget \
    htop \
    vim \
    libtinfo5 \
    libncursesw5 \
    python3-pip \
    python3-venv && \
    rm -rf /var/lib/apt/lists/*

# Copy and install Python dependencies (skip tensorflow since it's in the base image)
COPY src/setup/docker/requirements.txt /tmp/
RUN grep -v "^tensorflow==" /tmp/requirements.txt > /tmp/requirements_filtered.txt && \
    pip install --no-cache-dir -r /tmp/requirements_filtered.txt

# Additional TPU-related Python dependencies
RUN pip install --no-cache-dir \
    pandas \
    matplotlib \
    tensorboard \
    pyyaml \
    google-cloud-storage \
    google-api-python-client

# Create directories for mounting code and data
RUN mkdir -p /app/code /app/data /app/dev/src

# Copy the entrypoint script into the image
COPY src/setup/docker/entrypoint.sh /app/
RUN chmod +x /app/entrypoint.sh

# Set the entrypoint so that the container automatically configures the TPU environment
ENTRYPOINT ["/app/entrypoint.sh"]

# Default command (opens a shell)
CMD ["/bin/bash"]
