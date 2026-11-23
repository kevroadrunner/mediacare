"""Shared logging configuration for MediaCare."""

import logging
import sys


def configure_logging() -> None:
  logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-5s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    stream=sys.stdout,
  )
