# Use the official PyTorch base image (CPU version, as we install XLA later)
FROM pytorch/pytorch:2.1.0-cpu

# Set working directory
WORKDIR /app

# Copy requirements file
COPY setup/docker/requirements.txt .

# Install dependencies
RUN pip install --no-cache-dir -r requirements.txt \
    && pip install --no-cache-dir 'torch_xla[tpu]' -f https://storage.googleapis.com/libtpu-releases/index.html

# Copy the source code
COPY src/ .

# Set environment variables
ENV PJRT_DEVICE=TPU
ENV PYTHONUNBUFFERED=1
ENV LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib

# Verify PyTorch/XLA installation (using the shell script)
CMD ["python", "main.py"] 