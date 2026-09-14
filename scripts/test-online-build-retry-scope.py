#!/usr/bin/env python3
"""Policy regression tests for fail-fast online dependency acquisition."""

from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "build-full-bundle.sh"
DNS_PINS = ROOT / "deps" / "dns" / "pins.env"


def main() -> None:
    text = SCRIPT.read_text(encoding="utf-8")

    dns_marker = 'echo "build-full-bundle: CoreDNS acquisition attempt'
    control_plane_marker = "make package-control-plane-image-archive"
    if text.count(dns_marker) != 1:
        raise AssertionError("expected exactly one early CoreDNS acquisition block")
    if text.index(dns_marker) > text.index(control_plane_marker):
        raise AssertionError("CoreDNS must be acquired before the control-plane build")

    if "DNS_PACKAGE_ATTEMPTS=2" not in text:
        raise AssertionError("online CoreDNS package retries are not narrowly bounded")
    if "DNS_PACKAGE_ATTEMPTS=1" not in text:
        raise AssertionError("offline CoreDNS acquisition must remain single-attempt")

    removed_whole_run_markers = (
        "ONLINE_DEV_RUN_ATTEMPTS=",
        "DEV_RUN_ATTEMPTS=",
        "transient online dev-run network failure",
    )
    for marker in removed_whole_run_markers:
        if marker in text:
            raise AssertionError(f"whole dev-run retry returned: {marker}")

    if text.count('dev-run SCRIPT="${CODE_DEV_SCRIPT_REL}"') != 1:
        raise AssertionError("expected exactly one complete dev-run invocation")

    official_source = "docker.io/coredns/coredns:"
    if f"{official_source}${{DNS_VERSION}}" not in text:
        raise AssertionError("online CoreDNS must use the official Docker Hub source")
    if 'lan_cache_ref coredns "v${DNS_VERSION}"' not in text:
        raise AssertionError("offline CoreDNS must remain mapped to the LAN cache")

    dns_pins = DNS_PINS.read_text(encoding="utf-8")
    if "UPSTREAM_IMAGE=docker.io/coredns/coredns:1.14.4" not in dns_pins:
        raise AssertionError("CoreDNS seed and online upstream are not paired")
    if "CACHE_TAG=v1.14.4" not in dns_pins:
        raise AssertionError("CoreDNS LAN cache tag changed unexpectedly")

    print("online build retry-scope tests passed")


if __name__ == "__main__":
    main()
