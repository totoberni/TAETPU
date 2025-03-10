# Start from a slim Python image with a recent Python version (3.11) for PyTorch support
FROM python:3.11-slim

# TPU environment variables
ENV PJRT_DEVICE=TPU \
    XLA_USE_BF16=1 \
    PT_XLA_DEBUG_LEVEL=1 \
    XLA_METRICS_FILE=/tmp/xla_metrics.json \
    NEXT_PLUGGABLE_DEVICE_USE_C_API=true \
    TF_CPP_MIN_LOG_LEVEL=0 \
    XRT_TPU_CONFIG="localservice;0;localhost:51011" \
    TF_XLA_FLAGS=--tf_xla_enable_xla_devices \
    ALLOW_MULTIPLE_LIBTPU_LOAD=1 \
    PYTHONUNBUFFERED=1 \
    PATH="${PATH}:/app/utils/monitoring/backend:/app/.local/bin"

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libopenblas-dev \
    curl \
    wget \
    git \
    build-essential \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install Google Cloud SDK for gsutil and gcloud commands
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | \
    tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && \
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
    apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - && \
    apt-get update && apt-get install -y google-cloud-sdk && \
    rm -rf /var/lib/apt/lists/*

# Copy utils directory for common logging functions
COPY utils /app/utils

# Copy requirements.txt file
COPY requirements.txt /app/requirements.txt

# Install dependencies - using the recommended approach for TPU
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir numpy && \
    pip install --no-cache-dir torch~=2.6.0 'torch_xla[tpu]~=2.6.0' \
    -f https://storage.googleapis.com/libtpu-releases/index.html \
    -f https://storage.googleapis.com/libtpu-wheels/index.html && \
    pip install --no-cache-dir tensorboard==2.18.0

# Create required directories with proper structure
RUN mkdir -p /app/src \
             /app/utils/monitoring \
             /app/mount \
             /app/data \
             /app/models \
             /app/logs \
             /app/tensorboard

# Copy entrypoint script
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Setup Docker user with appropriate permissions for TPU access
RUN groupadd -g 1000 tpuuser && \
    useradd -u 1000 -g tpuuser -s /bin/bash -m tpuuser && \
    chown -R tpuuser:tpuuser /app

# Make sure gsutil will use the default service account
RUN echo '[GoogleCompute]\nservice_account = default' > /etc/boto.cfg

# Expose TensorBoard (6006) and app (5000) ports
EXPOSE 5000 6006

# Set the entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["python", "/app/src/main.py"]