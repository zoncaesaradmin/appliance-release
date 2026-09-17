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

    runtime_prefetch = (
        'oci_skopeo_prefetch_docker "\\${DNS_RUNTIME_SOURCE_IMAGE}" '
        '"\\${DNS_RUNTIME_LOCAL_REF}"'
    )
    dns_package = "make package-dns-server-image-archive"
    if runtime_prefetch not in text:
        raise AssertionError("CoreDNS runtime base is not explicitly prefetched")
    if text.index(runtime_prefetch) > text.index(dns_package):
        raise AssertionError("CoreDNS runtime base must be present before --pull-never")
    if '${CP_RUNTIME_IMAGE:-docker.io/library/alpine:3.24.1}' not in text:
        raise AssertionError("online CoreDNS runtime source must be fully qualified")
    # DNS package lines use the default twice (SOURCE + LOCAL_REF); freeze
    # fingerprint wiring may reference the same default elsewhere.
    if text.count('${CP_RUNTIME_IMAGE:-docker.io/library/alpine:3.24.1}') < 2:
        raise AssertionError("online CoreDNS runtime source and local tag must match")

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

    # Host-agentd is foundation/lan-discovery only; the in-cluster agent
    # binary is built inside the image Containerfile when NEED_HOST_AGENT_IMAGE=1.
    if 'NEED_HOST_AGENT_BINARY:-0' not in text:
        raise AssertionError("host-agentd packaging must gate on NEED_HOST_AGENT_BINARY")
    if text.count("make -C ./services/hostagent build-agentd GOOS=linux GOARCH=") != 1:
        raise AssertionError(
            "expected exactly one hostagent build-agentd packaging line with GOOS=linux GOARCH="
        )
    if "e_machine=" not in text or "host-agentd: ELF arch ok" not in text:
        raise AssertionError("host-agentd packaging must fail-closed on ELF TARGET_ARCH mismatch")
    if "make -C ./services/hostagent build\n" in text or 'make -C ./services/hostagent build"' in text:
        raise AssertionError("unconditional hostagent build returned; use build-agentd only")
    if "build-daemon" in text:
        raise AssertionError("legacy build-daemon target returned; use build-agentd")

    # acc-llm must package the runtime image in the dev script (TARGET_ARCH),
    # then tar the assembled pack after product-bundle — never tar workspace/out early.
    acc_package = 'INFERENCE_ARCHITECTURE=$(shell_quote "${TARGET_ARCH}")'
    acc_export = 'create_gzip_tarball "${ACC_LLM_ARCHIVE}"'
    product_bundle = 'make -C "${RELEASE_REPO_DIR}" product-bundle'
    if text.count(acc_package) < 1:
        raise AssertionError("expected TARGET_ARCH-driven inference package wiring")
    if text.count(acc_export) != 1:
        raise AssertionError("expected exactly one post-assemble acc-llm archive export")
    if text.index(acc_package) > text.index('cat >"${CODE_DEV_SCRIPT_PATH}"'):
        raise AssertionError("acc-llm package lines must be prepared before the dev script")
    if text.index(acc_export) < text.index(product_bundle):
        raise AssertionError("acc-llm archive export must run after product-bundle")
    if "acc-llm-arm64" in text or "acc-llm-amd64" in text or "std-llm-amd64" in text:
        raise AssertionError("legacy arch-suffixed pack IDs must not remain in build-full-bundle.sh")

    official_source = "docker.io/coredns/coredns:"
    if f"{official_source}${{DNS_VERSION}}" not in text:
        raise AssertionError("online CoreDNS must use the official Docker Hub source")
    if 'lan_cache_ref coredns "v${DNS_VERSION}-${TARGET_ARCH}"' not in text:
        raise AssertionError("offline CoreDNS must remain mapped to the LAN cache")

    dns_pins = DNS_PINS.read_text(encoding="utf-8")
    if "UPSTREAM_IMAGE=docker.io/coredns/coredns:1.14.4" not in dns_pins:
        raise AssertionError("CoreDNS seed and online upstream are not paired")
    if "CACHE_TAG_BASE=v1.14.4" not in dns_pins:
        raise AssertionError("CoreDNS LAN cache tag base changed unexpectedly")

    print("online build retry-scope tests passed")


if __name__ == "__main__":
    main()
