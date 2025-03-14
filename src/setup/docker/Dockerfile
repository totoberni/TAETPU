FROM python:3.11-slim

# Set essential environment variables
ENV PYTHONUNBUFFERED=1
ENV PJRT_DEVICE=TPU

WORKDIR /app

# Install minimal system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    libopenblas-dev \
    curl \
    wget \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies with PyTorch/XLA for TPU support
COPY src/setup/docker/requirements.txt /app/

# Install PyTorch and PyTorch/XLA with TPU support
RUN pip install --upgrade pip && \
    pip install torch~=2.6.0 'torch_xla[tpu]~=2.6.0' \
      -f https://storage.googleapis.com/libtpu-releases/index.html \
      -f https://storage.googleapis.com/libtpu-wheels/index.html && \
    # Install other requirements
    pip install -r requirements.txt && \
    # Clean up
    rm -rf /root/.cache/pip

# Create directory structure
RUN mkdir -p /app/mount /app/data /app/models /app/logs /app/tensorboard /app/keys

# Copy utility files
COPY src/utils/ /app/utils/

# Copy and set entrypoint
COPY src/setup/docker/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Expose ports
EXPOSE 5000 6006

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["bash"]