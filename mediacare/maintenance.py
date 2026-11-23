#!/usr/bin/env python3
"""MediaCare - surveillance video maintenance."""

from __future__ import annotations

import fcntl
import json
import logging
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time

from datetime import datetime
from pathlib import Path, PurePosixPath

# ============================================================
# Paths and configuration
# ============================================================

DATA_DIR = Path("/data")
APP_DIR = Path("/app")
STATE_DIR = APP_DIR / "state"

INDEX_FILE = STATE_DIR / "repair_index.log"
LOCK_FILE = STATE_DIR / "repair.lock"
STATUS_FILE = APP_DIR / "last_run.json"

GIB = 1024 ** 3

# ============================================================
# Structured logging
# ============================================================

logging.basicConfig(
  level=logging.INFO,
  format="%(asctime)s %(levelname)-5s %(message)s",
  datefmt="%Y-%m-%d %H:%M:%S",
  stream=sys.stdout,
)

logger = logging.getLogger("mediacare.maintenance")


# ============================================================
# Helpers
# ============================================================

def env_int(name: str, default: int, minimum: int = 0) -> int:
  raw = os.getenv(name, str(default))

  try:
    value = int(raw)
  except ValueError as exc:
    raise ValueError(
      f"{name} must be an integer; received: {raw}"
    ) from exc

  if value < minimum:
    raise ValueError(
      f"{name} must be at least {minimum}; received: {raw}"
    )

  return value


def relative(path: Path) -> str:
  return path.relative_to(DATA_DIR).as_posix()


def format_size(size: int) -> str:
  value = float(size)

  for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
    if value < 1024 or unit == "TiB":
      return f"{value:.1f} {unit}"

    value /= 1024

  return f"{value:.1f} TiB"


def walk_files() -> list[Path]:
  """Return regular files below DATA_DIR without following symlinks."""

  result = []

  for current, dirs, names in os.walk(DATA_DIR):
    dirs.sort()

    for name in names:
      path = Path(current) / name

      try:
        if stat.S_ISREG(path.lstat().st_mode):
          result.append(path)
      except OSError as exc:
        logger.warning(
          "Could not inspect file %s: %s",
          path,
          exc,
        )

  return result


def directory_size() -> int:
  """Calculate the total apparent size of regular files."""

  total = 0

  for path in walk_files():
    try:
      total += path.stat().st_size
    except OSError as exc:
      raise OSError(
        f"Could not read file size: {path}: {exc}"
      ) from exc

  return total


def atomic_write_text(path: Path, content: str) -> None:
  """Write a file atomically in its destination directory."""

  path.parent.mkdir(parents=True, exist_ok=True)

  fd, temp_name = tempfile.mkstemp(
    prefix=f".{path.name}.",
    suffix=".tmp",
    dir=path.parent,
  )

  try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
      handle.write(content)
      handle.flush()
      os.fsync(handle.fileno())

    os.replace(temp_name, path)

  except Exception:
    try:
      os.unlink(temp_name)
    except FileNotFoundError:
      pass

    raise


def atomic_write_json(path: Path, payload: dict) -> None:
  atomic_write_text(
    path,
    json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
  )


def load_index() -> set[str]:
  INDEX_FILE.touch(exist_ok=True)

  entries = set()

  for line in INDEX_FILE.read_text(encoding="utf-8").splitlines():
    entry = line.strip()

    if not entry:
      continue

    candidate = PurePosixPath(entry)

    # Only accept paths relative to /data.
    if candidate.is_absolute() or ".." in candidate.parts:
      logger.warning("Ignoring invalid repair index entry: %s", entry)
      continue

    entries.add(candidate.as_posix())

  return entries


def save_index(entries: set[str]) -> None:
  content = "".join(
    f"{entry}\n"
    for entry in sorted(entries)
  )

  atomic_write_text(INDEX_FILE, content)


def remove_file(path: Path, description: str) -> bool:
  try:
    path.unlink()
    logger.debug("%s: %s", description, relative(path))
    return True

  except FileNotFoundError:
    return False

  except OSError as exc:
    logger.error(
      "Could not %s %s: %s",
      description.lower(),
      path,
      exc,
    )
    return False


def log_tool_stderr(tool: str, stderr: str) -> None:
  for line in stderr.splitlines():
    if line.strip():
      logger.error("%s: %s", tool, line)


def run_command(args: list[str]) -> subprocess.CompletedProcess:
  return subprocess.run(
    args,
    capture_output=True,
    text=True,
    check=False,
  )


# ============================================================
# FFprobe and FFmpeg
# ============================================================

def probe_source(path: Path) -> bool:
  result = run_command(
    [
      "ffprobe",
      "-v", "error",
      "-show_entries", "stream=codec_type",
      "-of", "json",
      str(path),
    ]
  )

  if result.returncode != 0:
    log_tool_stderr("FFprobe", result.stderr)
    logger.error(
      "FFprobe could not inspect source file: %s",
      relative(path),
    )
    return False

  try:
    streams = json.loads(result.stdout).get("streams", [])
  except (json.JSONDecodeError, AttributeError):
    logger.error(
      "FFprobe returned invalid stream information: %s",
      relative(path),
    )
    return False

  has_supported_stream = any(
    stream.get("codec_type") in {"audio", "video"}
    for stream in streams
  )

  if not has_supported_stream:
    logger.error(
      "No audio or video streams found: %s",
      relative(path),
    )
    return False

  return True


def validate_output(path: Path) -> bool:
  result = run_command(
    [
      "ffprobe",
      "-v", "error",
      "-show_entries", "format=format_name,duration",
      "-of", "json",
      str(path),
    ]
  )

  if result.returncode != 0:
    log_tool_stderr("FFprobe", result.stderr)
    logger.error(
      "Repaired file failed FFprobe validation: %s",
      relative(path),
    )
    return False

  try:
    data = json.loads(result.stdout)
    return bool(data.get("format", {}).get("format_name"))

  except (json.JSONDecodeError, AttributeError):
    logger.error(
      "Repaired file returned invalid FFprobe output: %s",
      relative(path),
    )
    return False


def repair_file(path: Path) -> bool:
  temp_path = Path(f"{path}.repairing.mp4")

  try:
    temp_path.unlink(missing_ok=True)

    result = run_command(
      [
        "ffmpeg",
        "-y",
        "-hide_banner",
        "-loglevel", "error",
        "-i", str(path),
        "-map", "0",
        "-c", "copy",
        str(temp_path),
      ]
    )

    if result.returncode != 0:
      log_tool_stderr("FFmpeg", result.stderr)
      logger.error("FFmpeg failed: %s", relative(path))
      return False

    if not temp_path.is_file() or temp_path.stat().st_size == 0:
      logger.error(
        "FFmpeg produced an empty output: %s",
        relative(path),
      )
      return False

    if not validate_output(temp_path):
      return False

    original_stat = path.stat()

    # Preserve original access and modification timestamps.
    os.utime(
      temp_path,
      ns=(
        original_stat.st_atime_ns,
        original_stat.st_mtime_ns,
      ),
    )

    # Replace the original only after successful validation.
    os.replace(temp_path, path)

    return True

  except OSError as exc:
    logger.error(
      "Could not repair %s: %s",
      relative(path),
      exc,
    )
    return False

  finally:
    try:
      temp_path.unlink(missing_ok=True)
    except OSError as exc:
      logger.warning(
        "Could not remove temporary repair file %s: %s",
        temp_path,
        exc,
      )


# ============================================================
# Cleanup
# ============================================================

def remove_empty_directories() -> int:
  removed = 0

  for current, dirs, _ in os.walk(DATA_DIR, topdown=False):
    for name in dirs:
      directory = Path(current) / name

      try:
        directory.rmdir()
        removed += 1

        logger.debug(
          "Removed empty directory: %s",
          relative(directory),
        )

      except OSError:
        # Directory is not empty or cannot be removed.
        pass

  return removed


def cleanup_old_files(max_days: int, stats: dict) -> bool:
  logger.info("Removing files older than %s days.", max_days)

  cutoff = time.time() - max_days * 86400
  success = True

  for path in walk_files():
    if path.name.endswith(".repairing.mp4"):
      continue

    try:
      if path.stat().st_mtime < cutoff:
        if remove_file(path, "Deleted old file"):
          stats["deleted_old"] += 1
        elif path.exists():
          success = False

    except OSError as exc:
      logger.error(
        "Could not inspect old-file candidate %s: %s",
        path,
        exc,
      )
      success = False

  logger.info("Files deleted by age: %s", stats["deleted_old"])

  return success


def cleanup_stale_repairs(stats: dict) -> bool:
  logger.info("Removing leftover repair files.")

  success = True

  for path in walk_files():
    if path.name.endswith(".repairing.mp4"):
      if remove_file(path, "Removed stale repair file"):
        stats["stale_repairs"] += 1
      elif path.exists():
        success = False

  logger.info(
    "Stale repair files removed: %s",
    stats["stale_repairs"],
  )

  return success


def enforce_size_limit(limit_gb: int, index: set[str], stats: dict) -> tuple[bool, int]:
  limit_bytes = limit_gb * GIB

  logger.info("Checking storage limit (%s GB).", limit_gb)

  while True:
    size = directory_size()

    if size <= limit_bytes:
      logger.info("Current directory size: %s", format_size(size))
      return True, size

    candidates = [
      path
      for path in walk_files()
      if not path.name.endswith(".repairing.mp4")
    ]

    if not candidates:
      logger.error(
        "Size limit exceeded, but no deletable files were found."
      )
      return False, size

    try:
      oldest = min(
        candidates,
        key=lambda path: path.stat().st_mtime,
      )

    except OSError as exc:
      logger.error("Could not determine oldest file: %s", exc)
      return False, size

    logger.debug(
      "Deleting oldest file to enforce size limit: %s",
      relative(oldest),
    )

    if not remove_file(oldest, "Deleted file"):
      return False, size

    index.discard(relative(oldest))
    stats["deleted_size"] += 1

    logger.info(
      "Files deleted by size limit: %s",
      stats["deleted_size"],
    )


# ============================================================
# Status
# ============================================================

def write_status(
    status: str,
    started_at: str,
    start_epoch: float,
    stats: dict,
    limit_gb: int,
    final_size: int,
) -> None:
  finished_at = datetime.now().astimezone()

  payload = {
    "status": status,
    "started_at": started_at,
    "finished_at": finished_at.isoformat(timespec="seconds"),
    "duration_seconds": int(time.time() - start_epoch),
    "statistics": {
      "files_found": stats["total_files"],
      "files_checked": stats["checked"],
      "files_repaired": stats["repaired"],
      "files_failed": stats["failed"],
      "files_skipped": stats["skipped"],
      "files_deleted_by_age": stats["deleted_old"],
      "files_deleted_by_size": stats["deleted_size"],
      "stale_repairs_removed": stats["stale_repairs"],
      "empty_directories_removed": stats["empty_dirs"],
    },
    "storage": {
      "limit_gb": limit_gb,
      "final_size_bytes": final_size,
      "final_size_gb": round(final_size / GIB, 2),
    },
  }

  atomic_write_json(STATUS_FILE, payload)


# ============================================================
# Maintenance run
# ============================================================

def run_maintenance(
    limit_gb: int,
    max_days: int,
    repair_minutes: int,
) -> tuple[str, int, dict, int]:
  start_epoch = time.time()

  stats = {
    "total_files": 0,
    "checked": 0,
    "repaired": 0,
    "failed": 0,
    "skipped": 0,
    "deleted_old": 0,
    "deleted_size": 0,
    "stale_repairs": 0,
    "empty_dirs": 0,
  }

  fatal_error = False
  final_size = 0

  logger.info("============================================================")
  logger.info("MediaCare maintenance run started")
  logger.info("Data directory: %s", DATA_DIR)
  logger.info("Size limit: %s GB", limit_gb)
  logger.info("Maximum file age: %s days", max_days)
  logger.info("Minimum repair age: %s minutes", repair_minutes)
  logger.info("State directory: %s", STATE_DIR)

  index = load_index()
  logger.info("Indexed files: %s", len(index))

  if not cleanup_old_files(max_days, stats):
    fatal_error = True

  if not cleanup_stale_repairs(stats):
    fatal_error = True

  # Remove index entries for files that no longer exist.
  logger.info("Cleaning repair index.")

  index = {
    entry
    for entry in index
    if (DATA_DIR / entry).is_file()
  }

  logger.info("Repair index cleaned.")

  try:
    size_ok, final_size = enforce_size_limit(
      limit_gb,
      index,
      stats,
    )

    if not size_ok:
      fatal_error = True

  except OSError as exc:
    logger.error("Could not enforce storage limit: %s", exc)
    fatal_error = True

  # Find eligible MP4 files after retention and size cleanup.
  logger.info("Preparing MP4 repair.")

  files = sorted(
    (
      path
      for path in walk_files()
      if path.suffix.lower() == ".mp4"
         and not path.name.endswith(".repairing.mp4")
    ),
    key=lambda path: str(path),
  )

  stats["total_files"] = len(files)

  logger.info("MP4 files found: %s", len(files))
  logger.info("Starting MP4 container repair.")

  current_time = time.time()

  for number, path in enumerate(files, 1):
    if not path.is_file():
      continue

    rel = relative(path)

    if rel in index:
      stats["skipped"] += 1
      continue

    try:
      file_age = current_time - path.stat().st_mtime

    except OSError as exc:
      logger.warning(
        "Could not read file timestamp: %s (%s)",
        rel,
        exc,
      )
      stats["skipped"] += 1
      continue

    if file_age < repair_minutes * 60:
      stats["skipped"] += 1
      continue

    stats["checked"] += 1

    logger.debug(
      "[%s/%s] Repairing: %s",
      number,
      len(files),
      rel,
    )

    if not probe_source(path):
      stats["failed"] += 1
      continue

    if not repair_file(path):
      stats["failed"] += 1
      continue

    index.add(rel)
    stats["repaired"] += 1

    logger.debug("Repaired successfully: %s", rel)

    if number % 100 == 0:
      logger.info(
        "Progress: %s/%s | Checked: %s | Repaired: %s | "
        "Skipped: %s | Failed: %s",
        number,
        len(files),
        stats["checked"],
        stats["repaired"],
        stats["skipped"],
        stats["failed"],
      )

  # Commit the repair index only if maintenance-critical steps succeeded.
  logger.info("Updating repair index.")

  if not fatal_error:
    save_index(index)
    logger.info("Repair index updated successfully.")
  else:
    logger.error(
      "Repair index was not updated because a fatal error occurred."
    )

  logger.info("Removing empty directories.")
  stats["empty_dirs"] = remove_empty_directories()

  logger.info(
    "Empty directories removed: %s",
    stats["empty_dirs"],
  )

  try:
    final_size = directory_size()

  except OSError as exc:
    logger.error("Could not determine final directory size: %s", exc)
    fatal_error = True

  logger.info("============================================================")
  logger.info("Maintenance summary")
  logger.info("MP4 files found: %s", stats["total_files"])
  logger.info("Files checked: %s", stats["checked"])
  logger.info("Files repaired: %s", stats["repaired"])
  logger.info("Files failed: %s", stats["failed"])
  logger.info("Files skipped: %s", stats["skipped"])
  logger.info("Files deleted by age: %s", stats["deleted_old"])
  logger.info("Files deleted by size: %s", stats["deleted_size"])
  logger.info("Stale repair files removed: %s", stats["stale_repairs"])
  logger.info("Empty directories removed: %s", stats["empty_dirs"])
  logger.info("Final directory size: %s", format_size(final_size))
  logger.info("============================================================")

  if fatal_error:
    status = "failed"
    exit_code = 1
  elif stats["failed"] > 0:
    status = "warning"
    exit_code = 1
  else:
    status = "success"
    exit_code = 0

  return status, exit_code, stats, final_size


# ============================================================
# Main
# ============================================================

def main() -> int:
  start_epoch = time.time()
  started_at = datetime.now().astimezone().isoformat(timespec="seconds")

  try:
    limit_gb = env_int("LIMIT_GB", 100, minimum=1)
    max_days = env_int("MAX_DAYS", 7)
    repair_minutes = env_int("REPAIR_MINUTES", 20)

    if not DATA_DIR.is_dir():
      raise RuntimeError(
        f"Data directory does not exist: {DATA_DIR}"
      )

    STATE_DIR.mkdir(parents=True, exist_ok=True)

  except Exception as exc:
    logger.error("Configuration error: %s", exc)
    return 1

  # The lock is shared by scheduled and manual runs.
  with LOCK_FILE.open("a+") as lock_handle:
    try:
      fcntl.flock(
        lock_handle.fileno(),
        fcntl.LOCK_EX | fcntl.LOCK_NB,
      )

    except BlockingIOError:
      logger.info(
        "Another maintenance run is already active. "
        "Skipping this run."
      )
      return 0

    status = "failed"
    exit_code = 1
    stats = {
      "total_files": 0,
      "checked": 0,
      "repaired": 0,
      "failed": 0,
      "skipped": 0,
      "deleted_old": 0,
      "deleted_size": 0,
      "stale_repairs": 0,
      "empty_dirs": 0,
    }
    final_size = 0

    try:
      status, exit_code, stats, final_size = run_maintenance(
        limit_gb,
        max_days,
        repair_minutes,
      )

    except Exception:
      logger.exception("Fatal maintenance error.")
      status = "failed"
      exit_code = 1

    finally:
      try:
        write_status(
          status,
          started_at,
          start_epoch,
          stats,
          limit_gb,
          final_size,
        )

      except Exception:
        logger.exception("Could not write latest run status.")
        exit_code = 1

      if exit_code == 0:
        logger.info("Maintenance run completed.")
      else:
        logger.error(
          "Maintenance run finished with errors "
          "(exit code: %s).",
          exit_code,
        )

    return exit_code


if __name__ == "__main__":
  raise SystemExit(main())
