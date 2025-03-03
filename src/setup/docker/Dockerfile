# Use official TensorFlow image as base
FROM tensorflow/tensorflow:2.18.0

# Set working directory
WORKDIR /app

# Set environment variables for TPU support
ENV PYTHONUNBUFFERED=1 \
    PJRT_DEVICE=TPU \
    NEXT_PLUGGABLE_DEVICE_USE_C_API=true \
    TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so \
    TPU_NAME=local \
    TPU_LOAD_LIBRARY=0 \
    XLA_USE_BF16=1

# Install minimal system dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    wget && \
    rm -rf /var/lib/apt/lists/*

# Install minimal Python dependencies
RUN pip install --no-cache-dir \
    pandas \
    google-cloud-storage \
    tensorboard

# Create mount points
RUN mkdir -p /app/code /app/data

# Default command
CMD ["/bin/bash"]