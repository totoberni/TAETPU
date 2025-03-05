# Start from a slim Python image with a recent Python version (3.11) for PyTorch support
FROM python:3.11-slim

# Prevent Python from buffering stdout/stderr (for timely logs)
ENV PYTHONUNBUFFERED=1 

# Install system-level dependencies for PyTorch/XLA and performance monitoring
RUN apt-get update && apt-get install -y --no-install-recommends \
    libopenblas-dev \ 
    curl \
    wget \
    git \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Set working directory for the application
WORKDIR /app

# Accept build argument for PIP_EXTRA_INDEX_URL
ARG PIP_EXTRA_INDEX_URL

# Install Python dependencies separately to leverage caching
COPY requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt ${PIP_EXTRA_INDEX_URL:+-f $PIP_EXTRA_INDEX_URL}

# Copy application code and entrypoint script into the container
COPY . /app

# Ensure the entrypoint script has execute permission
RUN chmod +x /app/entrypoint.sh

# Environment variables for TPU execution (using PJRT runtime for Cloud TPU)
ENV PJRT_DEVICE=TPU

# Expose Flask (5000) and TensorBoard (6006) ports
EXPOSE 5000 6006

# Set the entrypoint to the startup script and default command to run Flask
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["flask", "run", "--host=0.0.0.0", "--port=5000"]
