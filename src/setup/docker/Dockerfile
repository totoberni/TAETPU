FROM python:3.11-slim

# Set essential environment variables (non-configurable ones only)
ENV PYTHONUNBUFFERED=1 \
    XLA_METRICS_FILE=/tmp/xla_metrics.json \
    PATH="${PATH}:/app/.local/bin"

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

# Install Google Cloud SDK
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | \
    tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && \
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
    apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - && \
    apt-get update && apt-get install -y google-cloud-sdk && \
    rm -rf /var/lib/apt/lists/*

# Copy requirements.txt and install dependencies
COPY requirements.txt /app/
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir numpy && \
    pip install --no-cache-dir torch~=2.6.0 'torch_xla[tpu]~=2.6.0' \
    -f https://storage.googleapis.com/libtpu-releases/index.html \
    -f https://storage.googleapis.com/libtpu-wheels/index.html && \
    pip install --no-cache-dir -r requirements.txt

# Copy utility files
COPY utils /app/utils

# Create required directories
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

# Set up user for TPU access
RUN groupadd -g 1000 tpuuser && \
    useradd -u 1000 -g tpuuser -s /bin/bash -m tpuuser && \
    chown -R tpuuser:tpuuser /app

# Configure gsutil
RUN echo '[GoogleCompute]\nservice_account = default' > /etc/boto.cfg

# Expose ports
EXPOSE 5000 6006

# Set entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["python", "/app/src/main.py"]