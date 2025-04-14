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

# Install minimal runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libopenblas-dev \
    && rm -rf /var/lib/apt/lists/*

# Create directory structure with our new organization
RUN mkdir -p /app/mount/src /app/mount/data /app/mount/models /app/mount/logs /app/tensorboard /app/keys

# Create symbolic links for backward compatibility
RUN ln -sf /app/mount/src /app/src && \
    ln -sf /app/mount/models /app/models && \
    ln -sf /app/mount/logs /app/logs && \
    ln -sf /app/mount/data /app/data

# Copy utilities
COPY infrastructure/utils/ /app/utils/

# Copy entrypoint script
COPY infrastructure/docker/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD python -c "import os; exit(0 if os.path.isdir('/app/mount') else 1)"

# Expose ports
EXPOSE 5000 6006

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["bash"]