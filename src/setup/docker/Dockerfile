# Start from a slim Python image with a recent Python version (3.11) for PyTorch support
FROM python:3.11-slim

# TPU environment variables
ENV PJRT_DEVICE=TPU \
    XLA_USE_BF16=1 \
    PT_XLA_DEBUG_LEVEL=1 \
    XLA_METRICS_FILE=/tmp/xla_metrics.json \
    NEXT_PLUGGABLE_DEVICE_USE_C_API=true \
    TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so \
    TF_ENABLE_ONEDNN_OPTS=0 \
    DNNL_MAX_CPU_ISA=AVX2 \
    TF_XLA_FLAGS="--tf_xla_enable_xla_devices --tf_xla_cpu_global_jit" \
    TF_CPP_MIN_LOG_LEVEL=0 \
    XRT_TPU_CONFIG="localservice;0;localhost:51011" \
    ALLOW_MULTIPLE_LIBTPU_LOAD=1 \
    PYTHONUNBUFFERED=1 \
    PATH="${PATH}:/app/scripts:/app/.local/bin"

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

# Copy scripts that were prepared by setup_image.sh
COPY app/scripts /app/scripts
RUN chmod +x /app/scripts/*.sh

# Copy entrypoint script
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Create required directories
RUN mkdir -p /app/src /app/source /app/data /app/models /app/logs

# Setup Docker user with appropriate permissions for TPU access
RUN groupadd -g 1000 tpuuser && \
    useradd -u 1000 -g tpuuser -s /bin/bash -m tpuuser && \
    chown -R tpuuser:tpuuser /app

# Expose Flask (5000) and TensorBoard (6006) ports
EXPOSE 5000 6006

# Set the entrypoint to the startup script and default command to run Flask
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["flask", "run", "--host=0.0.0.0", "--port=5000"]