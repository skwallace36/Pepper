"""pytest configuration — adds repo root to sys.path for pepper_ios imports."""

from __future__ import annotations

import os
import sys

# Allow test files to import pepper_ios package without install
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
