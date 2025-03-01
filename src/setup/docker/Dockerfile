# Use the official TensorFlow base image with TPU support
FROM tensorflow/tensorflow:2.15.0

# Set working directory
WORKDIR /app

# Install system dependencies for TPU
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    curl \
    libtinfo5 \
    libncursesw5 \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements file
COPY src/setup/docker/requirements.txt .

# Install all dependencies in a single layer to reduce potential caching issues
RUN pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir cloud-tpu-client && \
    pip install --no-cache-dir libtpu==0.0.7.1 tpu-info

# Copy the source code
COPY src/ .

# Set environment variables for TPU
ENV TF_CPP_MIN_LOG_LEVEL=0
ENV PYTHONUNBUFFERED=1
ENV LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib

# Default command
CMD ["python", "main.py"] 