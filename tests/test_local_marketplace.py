#!/usr/bin/env python3
"""Tests for the generated local marketplace catalog."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT_PATH = (
    Path(__file__).parents[1] / "scripts" / "prepare-local-marketplace.py"
)
SPEC = importlib.util.spec_from_file_location("prepare_local_marketplace", SCRIPT_PATH)
assert SPEC and SPEC.loader
marketplace = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(marketplace)


class LocalMarketplaceTests(unittest.TestCase):
    def test_writes_catalog_for_packaged_plugin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            build_root = Path(directory)
            manifest = build_root / "acme-appsec" / ".claude-plugin" / "plugin.json"
            manifest.parent.mkdir(parents=True)
            manifest.write_text('{"name":"acme-appsec"}\n', encoding="utf-8")

            result = marketplace.prepare(
                build_root, "acme-appsec", "acme-appsec-local"
            )
            catalog = json.loads(result.read_text(encoding="utf-8"))

            self.assertEqual(catalog["name"], "acme-appsec-local")
            self.assertEqual(
                catalog["plugins"],
                [{"name": "acme-appsec", "source": "./acme-appsec"}],
            )

    def test_requires_packaged_plugin_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(FileNotFoundError):
                marketplace.prepare(
                    Path(directory), "acme-appsec", "acme-appsec-local"
                )


if __name__ == "__main__":
    unittest.main()
