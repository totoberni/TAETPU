FROM us-central1-docker.pkg.dev/tpu-pytorch-releases/docker/xla:r2.6.0_3.10_tpuvm AS builder

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

# Copy requirements and install dependencies in a separate layer for better caching
COPY infrastructure/docker/requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt && \
    pip cache purge

# Final image - use the same TPU-specific base image for consistency
FROM us-central1-docker.pkg.dev/tpu-pytorch-releases/docker/xla:r2.6.0_3.10_tpuvm

# Set essential environment variables
ENV PYTHONUNBUFFERED=1
ENV PJRT_DEVICE=TPU

WORKDIR /app

# Copy Python packages from builder
COPY --from=builder /usr/local/lib/python3.10/site-packages/ /usr/local/lib/python3.10/site-packages/

# Install minimal runtime dependencies only
RUN apt-get update && apt-get install -y --no-install-recommends \
    libopenblas-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create the base mount directory
RUN mkdir -p /app/mount && chmod -R 777 /app/mount

# Health check to verify mount directory existence
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD python -c "import os; exit(0 if os.path.isdir('/app/mount') else 1)"

# Basic startup command
CMD ["bash"]