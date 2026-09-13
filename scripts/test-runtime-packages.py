#!/usr/bin/env python3
"""Exercise capability-to-package selection without building a GPU runtime."""
import copy
import importlib.util
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("release_index", SCRIPTS / "write-release-index.py")
index_writer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(index_writer)


class PackageSelectionTest(unittest.TestCase):
    def setUp(self):
        self.capabilities = {"base": {}, "inference": {}}
        self.packages = {
            "foundation": {"capabilities": ["base"]},
            "std-llm-amd64": {"capabilities": ["inference"], "inferenceEngine": "ollama"},
            "acc-llm-arm64": {"capabilities": ["inference"], "inferenceEngine": "vllm"},
        }
        self.profiles = {"cpu-host": {"capabilities": ["base", "inference"]}, "core": {"capabilities": ["base"]}}
        self.filenames = {p: f"appliance-1.0.0-{p}.tar.gz" for p in self.packages}

    def build(self):
        selected = getattr(self, "selected", {"foundation", "std-llm-amd64"})
        return index_writer.build_index("1.0.0", self.profiles, self.capabilities, self.packages, selected, self.filenames)

    def resolve(self, index, profile):
        script = (SCRIPTS / "install-release.sh").read_text()
        helpers = script[script.index("required_packs_for_profile_from_index()"):script.index("curl_download()")]
        helpers = helpers.replace("python3 - ", shlex.quote(sys.executable) + " -S - ")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "release-index.yaml"
            path.write_text(index_writer.render_index(index))
            return subprocess.run(["bash", "-c", helpers + "\nrequired_packs_for_profile_from_index \"$1\" \"$2\"", "test", str(path), profile], capture_output=True, text=True)

    def test_single_capability_owner_selects_package(self):
        index = self.build()
        self.assertEqual(index["capabilityPacks"]["inference"], "std-llm-amd64")
        for profile, package in (("cpu-host", "std-llm-amd64"), ("core", "")):
            result = self.resolve(index, profile)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), package)

    def test_duplicate_capability_ownership_fails_closed(self):
        self.packages["another-llm"] = copy.deepcopy(self.packages["std-llm-amd64"])
        self.filenames["another-llm"] = "appliance-1.0.0-another-llm.tar.gz"
        self.selected = {"foundation", "std-llm-amd64", "another-llm"}
        with self.assertRaises(ValueError):
            self.build()

    def test_missing_package_mapping_fails_closed(self):
        index = self.build()
        del index["capabilityPacks"]["inference"]
        result = self.resolve(index, "cpu-host")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
