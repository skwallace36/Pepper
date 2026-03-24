"""pytest configuration — adds tools/ to sys.path for all tests in this directory."""
from __future__ import annotations

import os
import sys

# Allow test files to import tools modules without install
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
