FROM python:3.11-slim AS builder

# Set essential environment variables
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# Install minimal system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libopenblas-dev \
    curl \
    wget \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies with PyTorch/XLA for TPU support
COPY infrastructure/docker/requirements.txt /app/

# Install PyTorch and PyTorch/XLA with TPU support in a separate layer
RUN pip install --upgrade pip && \
    pip install torch~=2.6.0 'torch_xla[tpu]~=2.6.0' \
      -f https://storage.googleapis.com/libtpu-releases/index.html \
      -f https://storage.googleapis.com/libtpu-wheels/index.html

# Install other requirements in a separate layer for better caching
RUN pip install -r requirements.txt && \
    pip cache purge

# Final image
FROM python:3.11-slim

# Set essential environment variables
ENV PYTHONUNBUFFERED=1
ENV PJRT_DEVICE=TPU

WORKDIR /app

# Copy Python packages from builder
COPY --from=builder /usr/local/lib/python3.11/site-packages/ /usr/local/lib/python3.11/site-packages/

# Install minimal runtime dependencies and Cloud Storage FUSE
RUN apt-get update && apt-get install -y --no-install-recommends \
    libopenblas-dev \
    curl \
    fuse \
    lsb-release \
    && export GCSFUSE_REPO=gcsfuse-`lsb_release -c -s` \
    && echo "deb https://packages.cloud.google.com/apt $GCSFUSE_REPO main" | tee /etc/apt/sources.list.d/gcsfuse.list \
    && curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add - \
    && apt-get update \
    && apt-get install -y gcsfuse \
    && rm -rf /var/lib/apt/lists/*

# Create only required directories
RUN mkdir -p /app/mount/src /app/gcs_mount/exp/datasets /app/gcs_mount/logs

# Create symbolic link for backward compatibility
RUN ln -sf /app/mount/src /app/src

# Health check for mount verification
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD python -c "import os; exit(0 if os.path.isdir('/app/mount') else 1)"

# Basic startup command
CMD ["bash"]