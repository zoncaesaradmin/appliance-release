#!/usr/bin/env python3
"""Local tests for build_catalog.py."""

import tempfile
from pathlib import Path

from build_catalog import builder_ssh_secret_names, load_build_catalog


def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def test_yaml_catalog_detects_ssh_repo() -> None:
    with tempfile.TemporaryDirectory(prefix="build-catalog-") as tmp_dir:
        path = Path(tmp_dir) / "catalog.yaml"
        write(
            path,
            """
workProfiles:
  - name: platform-dev
    repos:
      - name: forgeline
        enabledByDefault: true
repos:
  - name: forgeline
    url: git@github.com:zoncaesaradmin/forgeline.git
buildTargets:
  - name: forgeline
    repo: forgeline
    execution: repo_script
    imageRepository: users/example/forgeline
    builderImageDigest: registry.local/buildah@sha256:abc123
""".lstrip(),
        )
        catalog = load_build_catalog(path)
        if builder_ssh_secret_names(catalog) != ["builder-git-key", "builder-git-known-hosts"]:
            raise AssertionError(catalog)


def test_json_catalog_without_ssh_repo_has_no_managed_secrets() -> None:
    with tempfile.TemporaryDirectory(prefix="build-catalog-") as tmp_dir:
        path = Path(tmp_dir) / "catalog.json"
        write(
            path,
            '{"repos":[{"name":"app","url":"https://github.com/example/app.git"}],"buildTargets":[{"name":"app","repo":"app","execution":"repo_script","imageRepository":"users/example/app","builderImageDigest":"registry.local/buildah@sha256:abc123"}]}',
        )
        catalog = load_build_catalog(path)
        if builder_ssh_secret_names(catalog) != []:
            raise AssertionError(catalog)


if __name__ == "__main__":
    test_yaml_catalog_detects_ssh_repo()
    test_json_catalog_without_ssh_repo_has_no_managed_secrets()
