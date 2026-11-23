FROM python:3.13-slim-bookworm

ENV TZ=Europe/Berlin \
    CRON_SCHEDULE="0 */2 * * *" \
    LIMIT_GB=100 \
    MAX_DAYS=7 \
    REPAIR_MINUTES=20 \
    RUN_ON_START=false \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/mediacare/venv/bin:${PATH}"

# Install system dependencies
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ffmpeg \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/mediacare

# Create isolated Python environment
RUN python -m venv /opt/mediacare/venv

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application
COPY mediacare/ /opt/mediacare/mediacare/

VOLUME ["/data", "/app"]

ENTRYPOINT ["python", "-m", "mediacare"]
