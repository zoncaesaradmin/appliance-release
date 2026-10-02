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


def test_two_node_join_plan() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="target-plan-") as tmp:
        result = _parse(
            Path(tmp),
            "target_host:\n  alias: zonsys@192.168.1.151,zonsys@192.168.1.152\n"
            "  roles: prime,member\n",
            "emit_cluster_join_plan",
        )
        assert result.returncode == 0, result.stderr + result.stdout
        out = result.stdout
        assert "kind=prime-members" in out
        assert "prime=zonsys@192.168.1.151" in out
        assert "advertised_node=192-168-1-151" in out
        assert "endpoint=https://192.168.1.151:6443" in out
        assert "member enroll=192-168-1-152 join=zonsys@192.168.1.152 register-role=worker" in out
        assert "peer-prime" not in out


def test_three_prime_join_plan() -> None:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="target-ha-plan-") as tmp:
        result = _parse(
            Path(tmp),
            "target_host:\n  alias: a@10.0.0.1,a@10.0.0.2,a@10.0.0.3\n"
            "  roles: prime,prime,prime\n",
            "emit_cluster_join_plan",
        )
        assert result.returncode == 0, result.stderr + result.stdout
        out = result.stdout
        assert "kind=three-prime-ha" in out
        assert "peer-prime enroll=10-0-0-2 join=a@10.0.0.2 register-role=prime" in out
        assert "peer-prime enroll=10-0-0-3 join=a@10.0.0.3 register-role=prime" in out
        assert "member enroll=" not in out


def test_join_script_exists() -> None:
    script = Path(__file__).resolve().parent / "join-cluster-nodes-from-devhost.sh"
    text = script.read_text(encoding="utf-8")
    for want in (
        "cluster-enrollment-create",
        "cluster-node-register",
        "JOIN_ENROLLMENT_FILE",
        "--worker-role",
        "emit_cluster_join_plan",
    ):
        assert want in text, want


def main() -> None:
    test_single_alias_without_roles_is_implicit_prime()
    test_two_node_prime_member()
    test_three_prime_ha()
    test_reject_two_primes()
    test_reject_missing_roles_for_multi_node()
    test_reject_first_not_prime()
    test_reject_role_length_mismatch()
    test_node_name_from_ipv4_alias()
    test_append_cluster_alias_tls_sans()
    test_two_node_join_plan()
    test_three_prime_join_plan()
    test_join_script_exists()
    print("target host cluster tests passed")


if __name__ == "__main__":
    main()
