#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/app"
STATE_DIR="${APP_DIR}/state"
CRON_FILE="/tmp/mediacare.crontab"

mkdir -p "${STATE_DIR}"

if [[ -z "${CRON_SCHEDULE:-}" ]]; then
    echo "[ERROR] CRON_SCHEDULE must not be empty." >&2
    exit 1
fi

if [[ "${CRON_SCHEDULE}" == *$'\n'* || "${CRON_SCHEDULE}" == *$'\r'* ]]; then
    echo "[ERROR] CRON_SCHEDULE must contain exactly one cron expression." >&2
    exit 1
fi

printf '%s %s\n' "${CRON_SCHEDULE}" "/usr/local/bin/run-once.sh" > "${CRON_FILE}"

echo "============================================================"
echo "MediaCare"
echo "============================================================"
echo "[INFO] Data directory: /data"
echo "[INFO] Application directory: ${APP_DIR}"
echo "[INFO] Schedule: ${CRON_SCHEDULE}"
echo "[INFO] Run on start: ${RUN_ON_START:-false}"
echo

case "${RUN_ON_START,,}" in
    true|1|yes)
        echo "[INFO] Running initial maintenance pass."
        /usr/local/bin/run-once.sh || echo "[WARN] Initial maintenance pass returned a non-zero exit code."
        ;;
    false|0|no|"")
        ;;
    *)
        echo "[ERROR] RUN_ON_START must be true or false." >&2
        exit 1
        ;;
esac

echo "[INFO] Starting Supercronic."
exec /usr/local/bin/supercronic "${CRON_FILE}"
