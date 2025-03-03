# Use Python 3.8 as base
FROM python:3.8-slim

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install TPU libraries and TensorFlow for TPU
RUN pip install --no-cache-dir https://storage.googleapis.com/cloud-tpu-tpuvm-artifacts/tensorflow/tf-2.18.0/tensorflow-2.18.0-cp38-cp38-linux_x86_64.whl
RUN curl -L https://storage.googleapis.com/cloud-tpu-tpuvm-artifacts/libtpu/1.6.0/libtpu.so -o /lib/libtpu.so

# Copy requirements file
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Set TPU environment variables based on documentation
ENV TPU_NAME=local \
    PJRT_DEVICE=TPU \
    NEXT_PLUGGABLE_DEVICE_USE_C_API=true \
    TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so

# Default command
CMD ["/bin/bash"]