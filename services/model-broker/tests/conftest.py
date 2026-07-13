"""Make the stdlib-only broker module importable from the tests directory."""

import pathlib
import sys

BROKER_DIR = pathlib.Path(__file__).resolve().parent.parent
if str(BROKER_DIR) not in sys.path:
    sys.path.insert(0, str(BROKER_DIR))
