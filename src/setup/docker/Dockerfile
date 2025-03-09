# Start from a slim Python image with a recent Python version (3.11) for PyTorch support
FROM python:3.11-slim

# TPU environment variables and CPU compiler flags
ENV PJRT_DEVICE=TPU \
    XLA_USE_BF16=1 \
    PT_XLA_DEBUG_LEVEL=1 \
    XLA_METRICS_FILE=/tmp/xla_metrics.json \
    NEXT_PLUGGABLE_DEVICE_USE_C_API=true \
    TF_CPP_MIN_LOG_LEVEL=0 \
    XRT_TPU_CONFIG="localservice;0;localhost:51011" \
    ALLOW_MULTIPLE_LIBTPU_LOAD=1 \
    PYTHONUNBUFFERED=1 \
    PATH="${PATH}:/app/utils/monitoring/backend:/app/.local/bin"

# Install system-level dependencies for PyTorch/XLA and performance monitoring
RUN apt-get update && apt-get install -y --no-install-recommends \
    libopenblas-dev \ 
    curl \
    wget \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Set working directory for the application
WORKDIR /app

# Copy utils directory for common logging functions
COPY utils /app/utils

# Install Python dependencies
COPY requirements.txt /app/requirements.txt

# Install dependencies - split into two steps to improve caching
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir numpy torch==2.1.2 && \
    pip install --no-cache-dir -r /app/requirements.txt && \
    pip install --no-cache-dir torch-xla==2.1.0 -f https://storage.googleapis.com/libtpu-releases/index.html && \
    pip install --no-cache-dir optimum-tpu -f https://storage.googleapis.com/libtpu-releases/index.html

# Create required directories with proper structure
RUN mkdir -p /app/src \
             /app/utils/monitoring/backend \
             /app/mount \
             /app/data \
             /app/models \
             /app/logs

# Copy entrypoint script to monitoring backend
COPY entrypoint.sh /app/utils/monitoring/backend/entrypoint.sh
RUN chmod +x /app/utils/monitoring/backend/entrypoint.sh

# Setup Docker user with appropriate permissions for TPU access
RUN groupadd -g 1000 tpuuser && \
    useradd -u 1000 -g tpuuser -s /bin/bash -m tpuuser && \
    chown -R tpuuser:tpuuser /app

# Expose Flask (5000) and TensorBoard (6006) ports
EXPOSE 5000 6006

# Set the entrypoint to the monitoring backend script
ENTRYPOINT ["/app/utils/monitoring/backend/entrypoint.sh"]
CMD ["flask", "run", "--host=0.0.0.0", "--port=5000"]