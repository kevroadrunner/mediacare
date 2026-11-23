"""MediaCare maintenance scheduler."""

import os
import signal
import subprocess
import sys
import threading

from datetime import datetime
from zoneinfo import ZoneInfo

from croniter import croniter

from .logging_config import configure_logging
import logging


DEFAULT_SCHEDULE = "0 */2 * * *"

stop_event = threading.Event()

logger = logging.getLogger("mediacare.scheduler")


def handle_signal(signum, frame):
  logger.info("Received shutdown signal: %s", signum)
  stop_event.set()


def run_maintenance() -> int:
  logger.info("Starting maintenance run.")

  try:
    result = subprocess.run(
      [
        sys.executable,
        "-m",
        "mediacare.maintenance",
      ],
      check=False,
    )

  except OSError as exc:
    logger.error("Could not start maintenance: %s", exc)
    return 1

  if result.returncode == 0:
    logger.info("Maintenance process finished successfully.")
  else:
    logger.warning(
      "Maintenance process returned exit code %s.",
      result.returncode,
    )

  return result.returncode


def main() -> int:
  configure_logging()

  schedule = os.getenv(
    "CRON_SCHEDULE",
    DEFAULT_SCHEDULE,
  ).strip()

  run_on_start = os.getenv(
    "RUN_ON_START",
    "false",
  ).strip().lower()

  timezone_name = os.getenv("TZ", "Europe/Berlin")

  if not schedule or not croniter.is_valid(schedule):
    logger.error("Invalid CRON_SCHEDULE: %s", schedule)
    return 1

  if run_on_start not in {
    "true", "1", "yes",
    "false", "0", "no", "",
  }:
    logger.error("RUN_ON_START must be true or false.")
    return 1

  try:
    timezone = ZoneInfo(timezone_name)
  except Exception as exc:
    logger.error("Invalid timezone %s: %s", timezone_name, exc)
    return 1

  signal.signal(signal.SIGTERM, handle_signal)
  signal.signal(signal.SIGINT, handle_signal)

  logger.info("============================================================")
  logger.info("MediaCare")
  logger.info("============================================================")
  logger.info("Data directory: /data")
  logger.info("Application directory: /app")
  logger.info("Schedule: %s", schedule)
  logger.info("Timezone: %s", timezone_name)
  logger.info("Run on start: %s", run_on_start or "false")

  if run_on_start in {"true", "1", "yes"}:
    if not stop_event.is_set():
      run_maintenance()

  logger.info("Scheduler started.")

  while not stop_event.is_set():
    now = datetime.now(timezone)

    try:
      next_run = croniter(
        schedule,
        now,
      ).get_next(datetime)

    except (ValueError, KeyError) as exc:
      logger.error("Could not calculate next run: %s", exc)
      return 1

    delay = max(
      0,
      (next_run - now).total_seconds(),
    )

    logger.info(
      "Next maintenance run: %s",
      next_run.isoformat(timespec="seconds"),
    )

    if stop_event.wait(delay):
      break

    if stop_event.is_set():
      break

    run_maintenance()

  logger.info("Scheduler stopped.")
  return 0
