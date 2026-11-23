#!/usr/bin/env bash
set -uo pipefail

# ============================================================
# MediaCare - surveillance video maintenance
# ============================================================

DATA_DIR="/data"
APP_DIR="/app"
STATE_DIR="${APP_DIR}/state"

STATE_FILE="${STATE_DIR}/repair_index.log"
LOCK_FILE="${STATE_DIR}/repair.lock"
STATUS_FILE="${APP_DIR}/last_run.json"

LIMIT_GB="${LIMIT_GB:-100}"
MAX_DAYS="${MAX_DAYS:-7}"
REPAIR_MINUTES="${REPAIR_MINUTES:-20}"

# ============================================================
# Helpers and validation
# ============================================================

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S%z')" "$*"
}

is_positive_integer_or_zero() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

for setting in LIMIT_GB MAX_DAYS REPAIR_MINUTES; do
    value="${!setting}"
    if ! is_positive_integer_or_zero "$value"; then
        echo "[ERROR] ${setting} must be a non-negative integer; received: ${value}" >&2
        exit 1
    fi
done

if (( LIMIT_GB <= 0 )); then
    echo "[ERROR] LIMIT_GB must be greater than zero." >&2
    exit 1
fi

if [[ ! -d "${DATA_DIR}" ]]; then
    echo "[ERROR] Data directory does not exist: ${DATA_DIR}" >&2
    exit 1
fi

mkdir -p "${STATE_DIR}" || {
    echo "[ERROR] Could not create state directory: ${STATE_DIR}" >&2
    exit 1
}

# ============================================================
# Lock
#
# flock releases the lock automatically when the process exits.
# The lock file itself may remain on disk; that is intentional.
# ============================================================

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    log "Another maintenance run is already active. Skipping this run."
    exit 0
fi

# ============================================================
# Run state and counters
# ============================================================

START_EPOCH="$(date +%s)"
STARTED_AT="$(date --iso-8601=seconds)"
FINISHED_AT=""
RUN_STATUS="failed"
EXIT_CODE=1
FATAL_ERROR=0

CHECKED=0
REPAIRED=0
FAILED=0
SKIPPED=0
STALE_REPAIRS=0
DELETED_OLD=0
DELETED_SIZE=0
EMPTY_DIRS=0

TOTAL_FILES=0
FINAL_SIZE_BYTES=0
NEW_STATE=""

LIMIT_BYTES=$((LIMIT_GB * 1024 * 1024 * 1024))
REPAIR_MIN_AGE_SECONDS=$((REPAIR_MINUTES * 60))
MAX_AGE_MINUTES=$((MAX_DAYS * 24 * 60))

declare -A REPAIRED_FILES=()

write_status() {
    local end_epoch duration tmp_file final_size_gb

    end_epoch="$(date +%s)"
    FINISHED_AT="$(date --iso-8601=seconds)"
    duration=$((end_epoch - START_EPOCH))
    final_size_gb="$(awk -v bytes="${FINAL_SIZE_BYTES}" 'BEGIN { printf "%.2f", bytes / 1024 / 1024 / 1024 }')"
    tmp_file="${STATUS_FILE}.tmp.$$"

    if ! jq -n \
        --arg status "${RUN_STATUS}" \
        --arg started_at "${STARTED_AT}" \
        --arg finished_at "${FINISHED_AT}" \
        --argjson duration_seconds "${duration}" \
        --argjson files_found "${TOTAL_FILES}" \
        --argjson files_checked "${CHECKED}" \
        --argjson files_repaired "${REPAIRED}" \
        --argjson files_failed "${FAILED}" \
        --argjson files_skipped "${SKIPPED}" \
        --argjson files_deleted_by_age "${DELETED_OLD}" \
        --argjson files_deleted_by_size "${DELETED_SIZE}" \
        --argjson stale_repairs_removed "${STALE_REPAIRS}" \
        --argjson empty_directories_removed "${EMPTY_DIRS}" \
        --argjson limit_gb "${LIMIT_GB}" \
        --argjson final_size_bytes "${FINAL_SIZE_BYTES}" \
        --argjson final_size_gb "${final_size_gb}" \
        '{
          status: $status,
          started_at: $started_at,
          finished_at: $finished_at,
          duration_seconds: $duration_seconds,
          statistics: {
            files_found: $files_found,
            files_checked: $files_checked,
            files_repaired: $files_repaired,
            files_failed: $files_failed,
            files_skipped: $files_skipped,
            files_deleted_by_age: $files_deleted_by_age,
            files_deleted_by_size: $files_deleted_by_size,
            stale_repairs_removed: $stale_repairs_removed,
            empty_directories_removed: $empty_directories_removed
          },
          storage: {
            limit_gb: $limit_gb,
            final_size_bytes: $final_size_bytes,
            final_size_gb: $final_size_gb
          }
        }' > "${tmp_file}"; then
        log "ERROR: Could not generate run status JSON."
        rm -f -- "${tmp_file}"
        return 1
    fi

    if ! mv -f -- "${tmp_file}" "${STATUS_FILE}"; then
        log "ERROR: Could not update run status file."
        rm -f -- "${tmp_file}"
        return 1
    fi

    return 0
}

on_exit() {
    local original_exit_code="$1"

    if (( original_exit_code != 0 )) && [[ "${RUN_STATUS}" == "success" ]]; then
        RUN_STATUS="failed"
    fi

    if [[ -n "${NEW_STATE}" ]]; then
        rm -f -- "${NEW_STATE}"
    fi

    if ! write_status; then
        original_exit_code=1
    fi

    if (( original_exit_code == 0 )); then
        log "Maintenance run completed."
    else
        log "Maintenance run finished with errors (exit code: ${original_exit_code})."
    fi

    exit "${original_exit_code}"
}

trap 'on_exit $?' EXIT

# ============================================================
# Start
# ============================================================

log "============================================================"
log "MediaCare maintenance run started"
log "============================================================"
log "Data directory: ${DATA_DIR}"
log "Size limit: ${LIMIT_GB} GB"
log "Maximum file age: ${MAX_DAYS} days"
log "Minimum repair age: ${REPAIR_MINUTES} minutes"
log "State directory: ${STATE_DIR}"

if ! touch "${STATE_FILE}"; then
    log "ERROR: Could not access repair index: ${STATE_FILE}"
    FATAL_ERROR=1
    exit 1
fi

# Load existing repair index.
while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] && REPAIRED_FILES["${line}"]=1
done < "${STATE_FILE}"

log "Indexed files: ${#REPAIRED_FILES[@]}"

# ============================================================
# Remove files older than configured retention
# ============================================================

log "Removing files older than ${MAX_DAYS} days."

while IFS= read -r -d '' file; do
    if rm -f -- "${file}"; then
        DELETED_OLD=$((DELETED_OLD + 1))
        log "Deleted old file: ${file#${DATA_DIR}/}"
    else
        log "ERROR: Could not delete old file: ${file}"
        FATAL_ERROR=1
    fi
done < <(
    find "${DATA_DIR}" \
        -type f \
        ! -name '*.repairing.mp4' \
        -mmin "+${MAX_AGE_MINUTES}" \
        -print0
)

log "Files deleted by age: ${DELETED_OLD}"

# ============================================================
# Remove stale repair output files
# ============================================================

log "Removing leftover repair files."

while IFS= read -r -d '' file; do
    if rm -f -- "${file}"; then
        STALE_REPAIRS=$((STALE_REPAIRS + 1))
        log "Removed stale repair file: ${file#${DATA_DIR}/}"
    else
        log "ERROR: Could not remove stale repair file: ${file}"
        FATAL_ERROR=1
    fi
done < <(find "${DATA_DIR}" -type f -name '*.repairing.mp4' -print0)

log "Stale repair files removed: ${STALE_REPAIRS}"

# ============================================================
# Clean repair index
# ============================================================

log "Cleaning repair index."

CLEAN_STATE="${STATE_FILE}.cleaning.$$"
: > "${CLEAN_STATE}" || {
    log "ERROR: Could not create temporary repair index."
    FATAL_ERROR=1
    exit 1
}

for relative_file in "${!REPAIRED_FILES[@]}"; do
    if [[ -f "${DATA_DIR}/${relative_file}" ]]; then
        printf '%s\n' "${relative_file}" >> "${CLEAN_STATE}"
    fi
done

if mv -f -- "${CLEAN_STATE}" "${STATE_FILE}"; then
    log "Repair index cleaned."
else
    log "ERROR: Could not replace cleaned repair index."
    rm -f -- "${CLEAN_STATE}"
    FATAL_ERROR=1
fi

unset REPAIRED_FILES
declare -A REPAIRED_FILES=()

while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] && REPAIRED_FILES["${line}"]=1
done < "${STATE_FILE}"

# ============================================================
# Enforce directory size limit
# ============================================================

log "Checking storage limit (${LIMIT_GB} GB)."

while true; do
    SIZE="$(du -sb "${DATA_DIR}" 2>/dev/null | awk '{print $1}')"

    if [[ -z "${SIZE}" || ! "${SIZE}" =~ ^[0-9]+$ ]]; then
        log "ERROR: Could not determine data directory size."
        FATAL_ERROR=1
        break
    fi

    if (( SIZE <= LIMIT_BYTES )); then
        FINAL_SIZE_BYTES="${SIZE}"
        log "Current directory size: $(numfmt --to=iec "${SIZE}")"
        break
    fi

    oldest_record="$(
        find "${DATA_DIR}" \
            -type f \
            ! -name '*.repairing.mp4' \
            -printf '%T@ %p\0' |
        sort -z -n |
        head -z -n 1
    )"

    if [[ -z "${oldest_record}" ]]; then
        log "WARNING: Size limit exceeded, but no deletable files were found."
        FATAL_ERROR=1
        break
    fi

    oldest_file="${oldest_record#* }"
    log "Deleting oldest file to enforce size limit: ${oldest_file#${DATA_DIR}/}"

    if rm -f -- "${oldest_file}"; then
        DELETED_SIZE=$((DELETED_SIZE + 1))
    else
        log "ERROR: Could not delete file: ${oldest_file}"
        FATAL_ERROR=1
        break
    fi
done

log "Files deleted by size limit: ${DELETED_SIZE}"

# ============================================================
# Prepare MP4 repair
# ============================================================

log "Preparing MP4 repair."

CURRENT_TIME="$(date +%s)"
mapfile -d '' FILES < <(
    find "${DATA_DIR}" \
        -type f \
        -iname '*.mp4' \
        ! -name '*.repairing.mp4' \
        -print0
)

TOTAL_FILES="${#FILES[@]}"
log "MP4 files found: ${TOTAL_FILES}"

# Build a replacement index separately. The existing index remains
# intact until the completed index can be atomically moved into place.
NEW_STATE="${STATE_FILE}.updating.$$"
if ! cat "${STATE_FILE}" > "${NEW_STATE}"; then
    log "ERROR: Could not create updated repair index."
    FATAL_ERROR=1
    exit 1
fi

# ============================================================
# MP4 container repair
# ============================================================

log "Starting MP4 container repair."

CURRENT_FILE=0

for file in "${FILES[@]}"; do
    CURRENT_FILE=$((CURRENT_FILE + 1))

    [[ -f "${file}" ]] || continue

    relative_file="${file#${DATA_DIR}/}"

    if [[ -n "${REPAIRED_FILES[${relative_file}]+x}" ]]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    file_mtime="$(stat -c %Y -- "${file}" 2>/dev/null)" || {
        log "WARNING: Could not read file timestamp: ${relative_file}"
        SKIPPED=$((SKIPPED + 1))
        continue
    }

    file_age=$((CURRENT_TIME - file_mtime))
    if (( file_age < REPAIR_MIN_AGE_SECONDS )); then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    CHECKED=$((CHECKED + 1))
    log "[${CURRENT_FILE}/${TOTAL_FILES}] Repairing: ${relative_file}"

    tmp_file="${file}.repairing.mp4"
    rm -f -- "${tmp_file}"

    if ! ffmpeg \
        -y \
        -hide_banner \
        -loglevel error \
        -i "${file}" \
        -map 0 \
        -c copy \
        "${tmp_file}"; then
        log "ERROR: FFmpeg failed: ${relative_file}"
        rm -f -- "${tmp_file}"
        FAILED=$((FAILED + 1))
        continue
    fi

    if [[ ! -s "${tmp_file}" ]]; then
        log "ERROR: FFmpeg produced an empty output: ${relative_file}"
        rm -f -- "${tmp_file}"
        FAILED=$((FAILED + 1))
        continue
    fi

    if ! ffprobe \
        -v error \
        -show_entries format=format_name,duration \
        -of default=noprint_wrappers=1 \
        "${tmp_file}" >/dev/null 2>&1; then
        log "ERROR: Repaired file failed FFprobe validation: ${relative_file}"
        rm -f -- "${tmp_file}"
        FAILED=$((FAILED + 1))
        continue
    fi

    if ! touch -r "${file}" "${tmp_file}"; then
        log "ERROR: Could not preserve original timestamp: ${relative_file}"
        rm -f -- "${tmp_file}"
        FAILED=$((FAILED + 1))
        continue
    fi

    if ! mv -f -- "${tmp_file}" "${file}"; then
        log "ERROR: Could not replace original file: ${relative_file}"
        rm -f -- "${tmp_file}"
        FAILED=$((FAILED + 1))
        continue
    fi

    if ! printf '%s\n' "${relative_file}" >> "${NEW_STATE}"; then
        log "ERROR: Could not append file to repair index: ${relative_file}"
        FATAL_ERROR=1
        break
    fi

    REPAIRED_FILES["${relative_file}"]=1
    REPAIRED=$((REPAIRED + 1))
    log "Repaired successfully: ${relative_file}"

    if (( CURRENT_FILE % 100 == 0 )); then
        log "Progress: ${CURRENT_FILE}/${TOTAL_FILES} | Checked: ${CHECKED} | Repaired: ${REPAIRED} | Skipped: ${SKIPPED} | Failed: ${FAILED}"
    fi
done

# ============================================================
# Atomically commit repair index
# ============================================================

log "Updating repair index."

if (( FATAL_ERROR == 0 )); then
    if mv -f -- "${NEW_STATE}" "${STATE_FILE}"; then
        NEW_STATE=""
        log "Repair index updated successfully."
    else
        log "ERROR: Could not commit updated repair index."
        FATAL_ERROR=1
    fi
fi

# ============================================================
# Remove empty directories
# ============================================================

log "Removing empty directories."

while IFS= read -r directory; do
    [[ -n "${directory}" ]] || continue
    EMPTY_DIRS=$((EMPTY_DIRS + 1))
    log "Removed empty directory: ${directory#${DATA_DIR}/}"
done < <(
    find "${DATA_DIR}" \
        -depth \
        -mindepth 1 \
        -type d \
        -empty \
        -exec rmdir -- '{}' \; \
        -print
)

log "Empty directories removed: ${EMPTY_DIRS}"

# ============================================================
# Final statistics
# ============================================================

SIZE="$(du -sb "${DATA_DIR}" 2>/dev/null | awk '{print $1}')"
if [[ "${SIZE}" =~ ^[0-9]+$ ]]; then
    FINAL_SIZE_BYTES="${SIZE}"
else
    log "WARNING: Could not determine final directory size."
    FATAL_ERROR=1
fi

log "============================================================"
log "Maintenance summary"
log "============================================================"
log "MP4 files found: ${TOTAL_FILES}"
log "Files checked: ${CHECKED}"
log "Files repaired: ${REPAIRED}"
log "Files failed: ${FAILED}"
log "Files skipped: ${SKIPPED}"
log "Files deleted by age: ${DELETED_OLD}"
log "Files deleted by size: ${DELETED_SIZE}"
log "Stale repair files removed: ${STALE_REPAIRS}"
log "Empty directories removed: ${EMPTY_DIRS}"
log "Final directory size: $(numfmt --to=iec "${FINAL_SIZE_BYTES}")"
log "============================================================"

if (( FATAL_ERROR != 0 )); then
    RUN_STATUS="failed"
    EXIT_CODE=1
elif (( FAILED > 0 )); then
    RUN_STATUS="warning"
    EXIT_CODE=1
else
    RUN_STATUS="success"
    EXIT_CODE=0
fi

exit "${EXIT_CODE}"
