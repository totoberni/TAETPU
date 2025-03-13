FROM python:3.11-slim AS builder

# Set build environment variables
ENV PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

# Install system dependencies required for building
RUN apt-get update && apt-get install -y --no-install-recommends \
    libopenblas-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements file - paths relative to project root
COPY src/setup/docker/requirements.txt /app/

# Install all dependencies in a single layer for better caching
RUN pip install --upgrade pip && \
    pip install -r requirements.txt \
    -f https://storage.googleapis.com/libtpu-releases/index.html && \
    rm -rf /root/.cache/pip

# Runtime image
FROM python:3.11-slim

# Runtime environment variables
ENV PYTHONUNBUFFERED=1 \
    XLA_METRICS_FILE=/tmp/xla_metrics.json \
    PATH="${PATH}:/app/.local/bin"

WORKDIR /app

# Install runtime system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libopenblas-dev \
    curl \
    wget \
    git \
    && rm -rf /var/lib/apt/lists/*

# Copy Python packages from builder
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin

# Create directory structure
RUN mkdir -p /app/src \
             /app/utils/monitoring \
             /app/mount \
             /app/data \
             /app/models \
             /app/logs \
             /app/tensorboard && \
    echo '[GoogleCompute]\nservice_account = default' > /etc/boto.cfg

# Copy utility files - now with paths relative to project root
COPY src/utils/ /app/utils/

# Set up user for TPU access
RUN groupadd -g 1000 tpuuser && \
    useradd -u 1000 -g tpuuser -s /bin/bash -m tpuuser && \
    chown -R tpuuser:tpuuser /app

# Copy and set entrypoint
COPY src/setup/docker/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Expose ports
EXPOSE 5000 6006

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["bash"]