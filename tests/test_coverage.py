#!/usr/bin/env python3
"""Tests for the Bash line-coverage classifier."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "bash_coverage", ROOT / "tests" / "lib" / "coverage.py"
)
assert SPEC and SPEC.loader
coverage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(coverage)


class CoverableLinesTests(unittest.TestCase):
    def test_explicit_xtrace_off_region_is_not_reported_as_coverable(self) -> None:
        source = """\
echo before
set +x
secret_command
status=$?
set -x
echo after
"""
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "sample.sh"
            path.write_text(source, encoding="utf-8")
            self.assertEqual(coverage.coverable_lines(path), {1, 2, 6})

    def test_inline_disable_command_remains_coverable(self) -> None:
        source = """\
case "$-" in
  *x*) traced=true; set +x ;;
esac
hidden
set -x
visible
"""
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "sample.sh"
            path.write_text(source, encoding="utf-8")
            self.assertEqual(coverage.coverable_lines(path), {2, 6})


if __name__ == "__main__":
    unittest.main()
