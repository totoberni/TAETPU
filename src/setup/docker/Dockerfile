# Use Python 3.8 as base (TPU support is better established for 3.8)
FROM python:3.8-slim

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    build-essential \
    libssl-dev \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Install standard TensorFlow - we'll use the wheel that's known to work with TPUs
RUN pip install --no-cache-dir tensorflow==2.18.0

# Download the TPU driver library directly from Google Cloud Storage
# This is the official method recommended by Google
RUN curl -L -o /lib/libtpu.so https://storage.googleapis.com/cloud-tpu-tpuvm-artifacts/libtpu/1.6.0/libtpu.so && \
    chmod +x /lib/libtpu.so

# Create directory for TPU support files
RUN mkdir -p /usr/share/tpu

# Install Google Cloud SDK for gsutil and other tools
RUN wget -nv \
    https://dl.google.com/dl/cloudsdk/release/google-cloud-sdk.tar.gz && \
    mkdir -p /app/tools && \
    tar xvzf google-cloud-sdk.tar.gz -C /app/tools && \
    rm google-cloud-sdk.tar.gz && \
    /app/tools/google-cloud-sdk/install.sh --usage-reporting=false \
    --path-update=false --bash-completion=false \
    --disable-installation-options && \
    rm -rf /app/.config/* && \
    ln -s /app/.config /config && \
    # Remove the backup directory that gcloud creates
    rm -rf /app/tools/google-cloud-sdk/.install/.backup

# Path configuration for Google Cloud SDK
ENV PATH $PATH:/app/tools/google-cloud-sdk/bin

# Make sure gsutil will use the default service account
RUN echo '[GoogleCompute]\nservice_account = default' > /etc/boto.cfg

# Copy requirements file
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Set TPU environment variables based on documentation
ENV TPU_NAME=local \
    PJRT_DEVICE=TPU \
    NEXT_PLUGGABLE_DEVICE_USE_C_API=true \
    TF_PLUGGABLE_DEVICE_LIBRARY_PATH=/lib/libtpu.so \
    # CPU optimization flags for when TF compiles operations
    TF_ENABLE_ONEDNN_OPTS=0 \
    DNNL_MAX_CPU_ISA=AVX2 \
    # Enable vectorization and optimization
    TF_XLA_FLAGS="--tf_xla_enable_xla_devices --tf_xla_cpu_global_jit" \
    TF_CPP_MIN_LOG_LEVEL=0 \
    PYTHONUNBUFFERED=1 \
    XRT_TPU_CONFIG="localservice;0;localhost:51011" \
    ALLOW_MULTIPLE_LIBTPU_LOAD=1

# Create directories for model and data
RUN mkdir -p /app/model /app/data /app/scripts

# Copy entrypoint script
COPY entrypoint.sh /app/scripts/

# Make the entrypoint script executable
RUN chmod +x /app/scripts/entrypoint.sh

# Set the entrypoint
ENTRYPOINT ["/app/scripts/entrypoint.sh"]