# syntax=docker/dockerfile:1
FROM lscr.io/linuxserver/ffmpeg:latest

ARG TARGETARCH=amd64
ARG SUPERCRONIC_VERSION=0.2.33


ARG SUPERCRONIC_VERSION=0.2.33
ARG TARGETARCH

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        curl \
        findutils \
        jq \
        util-linux \
    && case "${TARGETARCH}" in \
         amd64) SUPERCRONIC_ARCH="amd64" ;; \
         arm64) SUPERCRONIC_ARCH="arm64" ;; \
         *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && curl -fsSL \
       "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-${SUPERCRONIC_ARCH}" \
       -o /usr/local/bin/supercronic \
    && chmod 0755 /usr/local/bin/supercronic \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/mediacare-entrypoint
COPY scripts/maintenance.sh /usr/local/bin/maintenance.sh
COPY scripts/run-once.sh /usr/local/bin/run-once.sh

RUN chmod 0755 \
      /usr/local/bin/mediacare-entrypoint \
      /usr/local/bin/maintenance.sh \
      /usr/local/bin/run-once.sh \
    && mkdir -p /data /app/state

ENV TZ=Europe/Berlin \
    CRON_SCHEDULE="0 */2 * * *" \
    LIMIT_GB=100 \
    MAX_DAYS=7 \
    REPAIR_MINUTES=20 \
    RUN_ON_START=false

VOLUME ["/data", "/app"]

ENTRYPOINT ["/usr/local/bin/mediacare-entrypoint"]
