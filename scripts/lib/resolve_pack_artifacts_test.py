#!/usr/bin/env python3
"""Tests for catalog pack → artifact resolution."""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RESOLVER = ROOT / "scripts" / "lib" / "resolve-pack-artifacts.py"
# Prefer sibling appliance-code catalogs in the operator workspace layout.
CODE_METADATA = ROOT.parent / "appliance-code" / "metadata-bundle" / "base"


class ResolvePackArtifactsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not (CODE_METADATA / "packages" / "catalog.yaml").is_file():
            raise unittest.SkipTest(f"appliance-code catalogs not found at {CODE_METADATA}")

    def _shell(self, packs: str) -> str:
        return subprocess.check_output(
            [
                sys.executable,
                str(RESOLVER),
                "--packages",
                str(CODE_METADATA / "packages" / "catalog.yaml"),
                "--capabilities",
                str(CODE_METADATA / "capabilities" / "catalog.yaml"),
                "--packs",
                packs,
                "--format",
                "shell",
            ],
            text=True,
        )

    def test_foundation_skips_dev_platform_artifacts(self):
        out = self._shell("foundation")
        self.assertIn("NEED_ARTIFACT_SERVER_IMAGE=0", out)
        self.assertIn("NEED_DNS_IMAGE=0", out)
        self.assertIn("NEED_HOST_AGENT_IMAGE=0", out)
        self.assertIn("NEED_CONTROL_PLANE_IMAGE=1", out)
        self.assertIn("NEED_HOST_AGENT_BINARY=1", out)
        self.assertIn("NEED_OPEN_WEBUI_IMAGE=0", out)
        self.assertIn("NEED_OPEN_WEBUI_GATEWAY_IMAGE=0", out)

    def test_foundation_plus_inference(self):
        out = self._shell("foundation acc-llm")
        self.assertIn("NEED_INFERENCE_RUNTIME_IMAGE=1", out)
        self.assertIn("NEED_INFERENCE_MANAGER_IMAGE=1", out)
        self.assertIn("NEED_OPEN_WEBUI_IMAGE=0", out)
        self.assertIn("NEED_OPEN_WEBUI_GATEWAY_IMAGE=0", out)
        self.assertIn("NEED_ARTIFACT_SERVER_IMAGE=0", out)
        self.assertIn("NEED_HOST_AGENT_BINARY=1", out)
        self.assertIn("NEED_HOST_AGENT_IMAGE=0", out)

    def test_foundation_plus_inference_plus_open_webui(self):
        out = self._shell("foundation acc-llm open-webui")
        self.assertIn("NEED_INFERENCE_RUNTIME_IMAGE=1", out)
        self.assertIn("NEED_OPEN_WEBUI_IMAGE=1", out)
        self.assertIn("NEED_OPEN_WEBUI_GATEWAY_IMAGE=1", out)

    def test_foundation_plus_deviceuser_needs_host_agent_image(self):
        out = self._shell("foundation deviceuser")
        self.assertIn("NEED_HOST_AGENT_BINARY=1", out)
        self.assertIn("NEED_HOST_AGENT_IMAGE=1", out)


if __name__ == "__main__":
    unittest.main()
