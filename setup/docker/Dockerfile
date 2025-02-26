# Use the official PyTorch base image (CPU version, as we install XLA later)
FROM pytorch/pytorch:2.6.0-cuda12.4-cudnn9-runtime

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
COPY setup/docker/requirements.txt .

# Install all dependencies in a single layer to reduce potential caching issues
RUN pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir torch_xla==2.6.0 -f https://storage.googleapis.com/libtpu-releases/index.html && \
    pip install --no-cache-dir libtpu==0.0.7.1 tpu-info

# Copy the source code
COPY setup/ .

# Set environment variables for TPU
ENV PJRT_DEVICE=TPU
ENV XLA_USE_BF16=1
ENV TF_CPP_MIN_LOG_LEVEL=0
ENV PYTHONUNBUFFERED=1
ENV LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib

# Default command
CMD ["python", "main.py"] 