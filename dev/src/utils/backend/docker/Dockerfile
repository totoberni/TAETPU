# src/backend/tensorboard/Dockerfile
FROM tensorflow/tensorflow:2.18.0

# Install additional packages
RUN pip install --no-cache-dir \
    tensorboard==2.18.* \
    google-cloud-storage>=2.10.0 \
    flask>=2.0.0 \
    gunicorn>=20.1.0 \
    python-dotenv>=1.0.1

# Copy necessary scripts
WORKDIR /app
COPY src/backend/tensorboard/start.sh /app/
COPY src/backend/tensorboard/server.py /app/

# Make the start script executable
RUN chmod +x /app/start.sh

# Environment variables (will be overridden by deployment)
ENV PORT=8080
ENV BUCKET_NAME="your-bucket-name"
ENV TENSORBOARD_LOG_DIR="tensorboard-logs"
ENV API_ENABLED="true"
ENV TENSORBOARD_PORT=6006
ENV TENSORBOARD_HOST=0.0.0.0

# Start TensorBoard with the right configuration
CMD ["/app/start.sh"]