FROM us-central1-docker.pkg.dev/tpu-pytorch-releases/docker/xla:r2.6.0_3.10_tpuvm

WORKDIR /app

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libopenblas-dev \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# Copy and install requirements
COPY infrastructure/docker/requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt && \
    pip cache purge

# Create mount directory with proper permissions
RUN mkdir -p /app/mount && chmod -R 777 /app/mount

# Keep container running
CMD ["bash", "-c", "tail -f /dev/null"]