#!/usr/bin/env python3
"""Local tests for build_catalog.py."""

import tempfile
from pathlib import Path

from build_catalog import load_build_catalog


def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def test_yaml_catalog_with_https_repo_loads() -> None:
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
    url: https://github.com/zoncaesaradmin/forgeline.git
buildTargets:
  - name: forgeline
    repo: forgeline
    execution: script
    args: [build.sh]
    imageRepository: users/example/forgeline
""".lstrip(),
        )
        catalog = load_build_catalog(path)
        if catalog["repos"][0]["url"] != "https://github.com/zoncaesaradmin/forgeline.git":
            raise AssertionError(catalog)


def test_json_catalog_with_https_repo_loads() -> None:
    with tempfile.TemporaryDirectory(prefix="build-catalog-") as tmp_dir:
        path = Path(tmp_dir) / "catalog.json"
        write(
            path,
            '{"repos":[{"name":"app","url":"https://github.com/example/app.git"}],"buildTargets":[{"name":"app","repo":"app","execution":"script","args":["build.sh"],"imageRepository":"users/example/app"}]}',
        )
        catalog = load_build_catalog(path)
        if catalog["repos"][0]["url"] != "https://github.com/example/app.git":
            raise AssertionError(catalog)


if __name__ == "__main__":
    test_yaml_catalog_with_https_repo_loads()
    test_json_catalog_with_https_repo_loads()
