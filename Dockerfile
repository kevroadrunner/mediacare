
FROM lscr.io/linuxserver/ffmpeg:latest

ENV TZ=Europe/Berlin \
    CRON_SCHEDULE="0 */2 * * *" \
    LIMIT_GB=100 \
    MAX_DAYS=7 \
    REPAIR_MINUTES=20 \
    RUN_ON_START=false \
    PATH="/opt/mediacare/venv/bin:${PATH}"

RUN apk add --no-cache \
        python3 \
        py3-pip \
        tzdata \
    && python3 -m venv /opt/mediacare/venv

WORKDIR /opt/mediacare

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY mediacare/ ./mediacare/

VOLUME ["/data", "/app"]

ENTRYPOINT ["python3", "-m", "mediacare"]
