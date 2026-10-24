#!/usr/bin/env python3
"""Tests for prime/member target_host.alias + target_host.roles parsing."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

COMMON_SH = Path(__file__).resolve().parent / "common.sh"


def _bash(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-lc", script],
        check=False,
        text=True,
        capture_output=True,
        env=os.environ.copy(),
    )


def _parse(tmp: Path, body: str, extra: str = "") -> subprocess.CompletedProcess[str]:
    cfg = tmp / "devhost.yaml"
    cfg.write_text(body, encoding="utf-8")
    return _bash(
        f'source "{COMMON_SH}"; parse_target_host_cluster "{cfg}"; {extra}'
    )


def test_single_alias_without_roles_is_implicit_prime(tmp_path: Path | None = None) -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="target-single-") as tmp:
        result = _parse(
            Path(tmp),
            "target_host:\n  alias: zonsys@192.168.1.151\n",
            'printf "%s|%s|%s|%s\\n" "${TARGET_HOST}" "${TARGET_PRIME_HOST}" '
            '"${TARGET_PRIME_COUNT}" "${TARGET_CLUSTER_KIND}"',
        )
        assert result.returncode == 0, result.stderr + result.stdout
        assert result.stdout.strip() == "zonsys@192.168.1.151|zonsys@192.168.1.151|1|single"


def test_two_node_prime_member() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="target-two-") as tmp:
        result = _parse(
            Path(tmp),
            "target_host:\n  alias: zonsys@192.168.1.151,zonsys@192.168.1.152\n"
            "  roles: prime,member\n",
            'printf "%s|%s|%s|%s\\n" "${TARGET_CLUSTER_KIND}" "${TARGET_PRIME_COUNT}" '
            '"${TARGET_HOST}" "$(printf "%s" "${TARGET_MEMBER_ALIASES}" | tr -d "\\n")"',
        )
        assert result.returncode == 0, result.stderr + result.stdout
        assert result.stdout.strip() == "prime-members|1|zonsys@192.168.1.151|zonsys@192.168.1.152"


def test_three_prime_ha() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="target-ha-") as tmp:
        result = _parse(
            Path(tmp),
            "target_host:\n  alias: a@10.0.0.1,a@10.0.0.2,a@10.0.0.3\n"
            "  roles: prime,prime,prime\n",
            'printf "%s|%s|%s\\n" "${TARGET_CLUSTER_KIND}" "${TARGET_PRIME_COUNT}" '
            '"$(printf "%s" "${TARGET_PEER_PRIME_ALIASES}" | tr "\\n" ",")"',
        )
        assert result.returncode == 0, result.stderr + result.stdout
        assert result.stdout.strip() == "three-prime-ha|3|a@10.0.0.2,a@10.0.0.3,"


def test_product_runner_requires_exactly_three_active_servers() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="target-product-topology-") as tmp:
        result = _parse(
            Path(tmp),
            "target_host:\n  alias: a@10.0.0.1,a@10.0.0.2,a@10.0.0.3\n"
            "  roles: prime,prime,prime\n",
            "require_three_server_product_targets",
        )
        assert result.returncode == 0, result.stderr + result.stdout

        result = _parse(
            Path(tmp),
            "target_host:\n  alias: a@10.0.0.1\n",
            "require_three_server_product_targets",
        )
        assert result.returncode != 0
        assert "exactly three active server targets" in result.stderr


def test_three_prime_inventory_is_direct_and_host_portable() -> None:
    import json
    import tempfile

    with tempfile.TemporaryDirectory(prefix="target-ha-inventory-") as tmp:
        inventory = Path(tmp) / "inventory.json"
        result = _parse(
            Path(tmp),
            "target_host:\n  alias: a@10.0.0.1,a@10.0.0.2,a@10.0.0.3\n"
            "  roles: prime,prime,prime\n",
            f'write_three_server_inventory "{inventory}"',
        )
        assert result.returncode == 0, result.stderr + result.stdout
        payload = json.loads(inventory.read_text(encoding="utf-8"))
        assert payload == {
            "topology": "three-server-etcd-v1",
            "bootstrapNode": "10-0-0-1",
            "nodes": [
                {"name": "10-0-0-1", "address": "10.0.0.1"},
                {"name": "10-0-0-2", "address": "10.0.0.2"},
                {"name": "10-0-0-3", "address": "10.0.0.3"},
            ],
        }


def test_reject_two_primes() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="target-two-prime-") as tmp:
        result = _parse(
            Path(tmp),
            "target_host:\n  alias: a@10.0.0.1,a@10.0.0.2\n  roles: prime,prime\n",
        )
        assert result.returncode != 0
        assert "three primes" in result.stderr


def test_reject_missing_roles_for_multi_node() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="target-no-roles-") as tmp:
        result = _parse(
            Path(tmp),
            "target_host:\n  alias: a@10.0.0.1,a@10.0.0.2\n",
        )
        assert result.returncode != 0
        assert "multi-node requires target_host.roles" in result.stderr


def test_reject_first_not_prime() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="target-member-first-") as tmp:
        result = _parse(
            Path(tmp),
            "target_host:\n  alias: a@10.0.0.1,a@10.0.0.2\n  roles: member,prime\n",
        )
        assert result.returncode != 0
        assert "first host must be prime" in result.stderr


def test_reject_role_length_mismatch() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="target-len-") as tmp:
        result = _parse(
            Path(tmp),
            "target_host:\n  alias: a@10.0.0.1,a@10.0.0.2\n  roles: prime\n",
        )
        assert result.returncode != 0
        assert "one entry per target_host.alias" in result.stderr


def test_node_name_from_ipv4_alias() -> None:
    result = _bash(
        f'source "{COMMON_SH}"; target_node_name_from_alias zonsys@192.168.1.152'
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "192-168-1-152"


def test_append_cluster_alias_tls_sans() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="target-sans-") as tmp:
        result = _parse(
            Path(tmp),
            "target_host:\n  alias: zonsys@192.168.1.151,zonsys@192.168.1.152\n"
            "  roles: prime,member\n",
            'EXTRA_TLS_SANS="demo.example"; append_cluster_alias_tls_sans; '
            'printf "%s\\n" "${EXTRA_TLS_SANS}"',
        )
        assert result.returncode == 0, result.stderr + result.stdout
        parts = result.stdout.strip().split()
        assert "demo.example" in parts
        assert "192.168.1.151" in parts
        assert "192.168.1.152" in parts


def test_three_server_stage_plan_rejects_legacy_layout() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="target-plan-") as tmp:
        result = _parse(
            Path(tmp),
            "target_host:\n  alias: zonsys@192.168.1.151,zonsys@192.168.1.152\n"
            "  roles: prime,member\n",
            "emit_three_server_stage_plan",
        )
        assert result.returncode != 0
        assert "requires exactly three active server targets" in result.stderr


def test_three_prime_join_plan() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="target-ha-plan-") as tmp:
        result = _parse(
            Path(tmp),
            "target_host:\n  alias: a@10.0.0.1,a@10.0.0.2,a@10.0.0.3\n"
            "  roles: prime,prime,prime\n",
            "emit_three_server_stage_plan",
        )
        assert result.returncode == 0, result.stderr + result.stdout
        out = result.stdout
        assert "kind=three-prime-ha" in out
        assert "server-stage node=10-0-0-2 host=a@10.0.0.2" in out
        assert "server-stage node=10-0-0-3 host=a@10.0.0.3" in out
        assert "cluster-finalize host=a@10.0.0.1" in out


def test_snapshot_newline_list_survives_stdin_drain() -> None:
    result = _bash(
        f'source "{COMMON_SH}"; '
        'snapshot_newline_list $\'a@10.0.0.2\\na@10.0.0.3\\n\' items; '
        '{ cat >/dev/null; printf "%s," "${items[@]}"; } <<< $\'stolen\\n\''
    )
    assert result.returncode == 0, result.stderr + result.stdout
    assert result.stdout.strip() == "a@10.0.0.2,a@10.0.0.3,"


def test_run_ssh_captured_does_not_consume_stdin() -> None:
    text = COMMON_SH.read_text(encoding="utf-8")
    assert 'stdin=subprocess.DEVNULL' in text
    assert "ssh -q -T -n \\" in text or 'ssh -q -T -n' in text
    assert '</dev/null >"${log_file}"' in text


def test_verify_target_probes_every_prime_ip() -> None:
    script = Path(__file__).resolve().parent / "verify-target.sh"
    text = script.read_text(encoding="utf-8")
    for want in (
        "cluster-etcd",
        "cluster-api",
        "cluster-https",
        "probe_k3s_api_ip",
        "probe_prime_https_ip",
        "/readyz",
        "cluster-ha-check",
        "application HTTPS HA: pending",
    ):
        assert want in text, want
    common = COMMON_SH.read_text(encoding="utf-8")
    assert "https://${ip}:6443/readyz" in common
    assert "401|403" in common


def test_join_script_exists() -> None:
    script = Path(__file__).resolve().parent / "join-cluster-nodes-from-devhost.sh"
    text = script.read_text(encoding="utf-8")
    for want in (
        "snapshot_newline_list",
        "</dev/null",
        "run_three_server_flow",
        "cluster-server-enrollment-create",
        "THREE_SERVER_OPERATION stage",
        "THREE_SERVER_OPERATION finalize",
        "target-three-server-enrollment-mode-",
        "chmod 0600 \"${enrollment_local}\"",
        "trap \\\"rm -f -- ${enrollment_file_q}\\\" EXIT",
        "require_three_server_product_targets",
        "emit_three_server_stage_plan",
    ):
        assert want in text, want
    for forbidden in (
        "cluster-enrollment-create",
        "cluster-node-register",
        "JOIN_ENROLLMENT_FILE",
        "--worker-role",
        "PRIME_NODE_NAME",
        "target-cluster-enroll-",
        "target-cluster-register-",
    ):
        assert forbidden not in text, forbidden
    assert "sudo -n zonctl" not in text
    assert 'done <<<"${TARGET_PEER_PRIME_ALIASES:-}"' not in text
    assert 'done <<<"${TARGET_MEMBER_ALIASES:-}"' not in text


def test_release_runner_cannot_select_a_legacy_target_shape() -> None:
    runner = Path(__file__).resolve().parent / "run-release-from-devhost.sh"
    text = runner.read_text(encoding="utf-8")
    assert "parse_target_host_cluster \"${DEVHOST_CONFIG}\"" in text
    assert "require_three_server_product_targets" in text
    assert "clusterStageFinalize (three active servers)" in text
    assert "clusterJoin (legacy prime/member extra hosts)" not in text

    installer = Path(__file__).resolve().parent / "run-install-via-public-helper-on-target.sh"
    installer_text = installer.read_text(encoding="utf-8")
    assert "require_three_server_product_targets" in installer_text
    assert "uninstalling members and extra primes before advertised prime reinstall" not in installer_text


def main() -> None:
    test_single_alias_without_roles_is_implicit_prime()
    test_two_node_prime_member()
    test_three_prime_ha()
    test_product_runner_requires_exactly_three_active_servers()
    test_three_prime_inventory_is_direct_and_host_portable()
    test_reject_two_primes()
    test_reject_missing_roles_for_multi_node()
    test_reject_first_not_prime()
    test_reject_role_length_mismatch()
    test_node_name_from_ipv4_alias()
    test_append_cluster_alias_tls_sans()
    test_three_server_stage_plan_rejects_legacy_layout()
    test_three_prime_join_plan()
    test_snapshot_newline_list_survives_stdin_drain()
    test_run_ssh_captured_does_not_consume_stdin()
    test_verify_target_probes_every_prime_ip()
    test_join_script_exists()
    test_release_runner_cannot_select_a_legacy_target_shape()
    print("target host cluster tests passed")


if __name__ == "__main__":
    main()
