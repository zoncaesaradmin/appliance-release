#!/usr/bin/env python3
"""Project canonical metadata onto the packages in a release bundle."""

import json
import re
import sys
from pathlib import Path


def identifier(value):
    return isinstance(value, str) and re.fullmatch(r"[a-z][a-z0-9-]*", value)


def build_index(version, profiles, capabilities, packages, selected, filenames):
    if not profiles or not capabilities or not packages:
        raise ValueError("profiles, capabilities, and packages catalogs must be nonempty")
    owners, package_caps = {}, {}
    for package, entry in packages.items():
        if not identifier(package) or not isinstance(entry, dict):
            raise ValueError(f"invalid package {package!r}")
        caps = entry.get("capabilities")
        if not isinstance(caps, list) or not caps or len(caps) != len(set(caps)):
            raise ValueError(f"package {package!r} needs distinct capabilities")
        package_caps[package] = sorted(caps)
        if package not in selected:
            continue
        for capability in caps:
            if capability not in capabilities:
                raise ValueError(f"package {package!r} references unknown capability {capability!r}")
            if capability == "inference":
                runtime = entry.get("runtime")
                if not isinstance(runtime, dict) or not identifier(runtime.get("inferenceEngine")) or not identifier(runtime.get("architecture")):
                    raise ValueError(f"package {package!r} needs runtime inferenceEngine and architecture")
            if capability in owners:
                raise ValueError(f"ambiguous package ownership for {capability}")
            owners[capability] = package
    profile_entries = {}
    for name, entry in sorted(profiles.items()):
        if not identifier(name) or not isinstance(entry, dict):
            raise ValueError(f"invalid profile {name!r}")
        caps = entry.get("capabilities")
        if not isinstance(caps, list) or not caps or set(caps) - set(capabilities):
            raise ValueError(f"profile {name!r} has invalid capabilities")
        profile_entries[name] = {"capabilities": caps}

    if set(selected) - set(packages) or set(selected) - set(filenames):
        raise ValueError("selected packages lack metadata or archive filenames")
    return {
        "version": version,
        "packs": [{"id": package, "filename": filenames[package], "capabilities": package_caps[package]} for package in filenames if package in selected],
        "capabilityPacks": {cap: package for cap, package in owners.items() if package in selected},
        "profiles": profile_entries,
    }


def render_index(index):
    # Inline JSON is valid YAML and lets the air-gapped install helper read the
    # exact emitted shape using only Python's standard library.
    lines = [f"version: {index['version']}", "packs:"]
    for pack in index["packs"]:
        lines += [f"  - id: {pack['id']}", f"    filename: {pack['filename']}", f"    capabilities: [{', '.join(pack['capabilities'])}]"]
    lines.append("capabilityPacks:")
    lines += [f"  {cap}: {package}" for cap, package in sorted(index["capabilityPacks"].items())]
    lines.append("profiles:")
    for name, profile in index["profiles"].items():
        lines += [f"  {name}:", f"    capabilities: [{', '.join(profile['capabilities'])}]"]
    return "\n".join(lines) + "\n"


def main():
    import yaml  # Build-host dependency; target parsing needs no PyYAML.

    index_path, version, profiles_path, capabilities_path, packages_path = sys.argv[1:6]
    args = sys.argv[6:]
    if len(args) < 5:
        raise ValueError("expected selected package IDs followed by package filenames")
    selected_args = set(args[:-4])
    if {"std-llm-amd64", "acc-llm-arm64"} <= selected_args:
        filename_names = ("foundation", "dev-platform", "deviceuser", "std-llm-amd64", "acc-llm-arm64")
    elif "acc-llm-arm64" in selected_args:
        filename_names = ("foundation", "dev-platform", "deviceuser", "acc-llm-arm64")
    else:
        filename_names = ("foundation", "dev-platform", "deviceuser", "std-llm-amd64")
    filenames = dict(zip(filename_names, args[-len(filename_names):]))
    profiles = yaml.safe_load(Path(profiles_path).read_text())["profiles"]
    capabilities = yaml.safe_load(Path(capabilities_path).read_text())["capabilities"]
    packages = yaml.safe_load(Path(packages_path).read_text())["packages"]
    index = build_index(version, profiles, capabilities, packages, set(args[:-len(filename_names)]), filenames)
    Path(index_path).write_text(render_index(index), encoding="utf-8")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, ImportError) as exc:
        raise SystemExit(f"release-index writer: {exc}")
