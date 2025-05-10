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
    python -m spacy download en_core_web_sm && \
    pip cache purge
# Create mount directory with proper permissions
RUN mkdir -p /app/mount && chmod -R 777 /app/mount

# Add healthcheck to verify TPU setup
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD python -c "import torch_xla.core.xla_model as xm; print(xm.get_xla_supported_devices('TPU'))" || exit 1

# Keep container running
CMD ["bash", "-c", "tail -f /dev/null"]