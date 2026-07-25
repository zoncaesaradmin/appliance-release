#!/usr/bin/env python3
"""Query an A record from 127.0.0.1:53 (hostNetwork CoreDNS) without dig(1)."""

from __future__ import annotations

import socket
import struct
import sys


def query_a(name: str, server: str = "127.0.0.1", port: int = 53, timeout: float = 3.0) -> str:
    labels = name.strip(".").split(".")
    qname = b"".join(bytes([len(part)]) + part.encode("ascii") for part in labels) + b"\x00"
    packet = struct.pack("!HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0) + qname + struct.pack("!HH", 1, 1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(packet, (server, port))
        data, _ = sock.recvfrom(512)
    finally:
        sock.close()
    if len(data) < 12:
        raise RuntimeError("short DNS response")
    ancount = struct.unpack("!H", data[6:8])[0]
    i = 12
    while i < len(data) and data[i] != 0:
        i += data[i] + 1
    i += 5  # null + qtype + qclass
    for _ in range(ancount):
        if i >= len(data):
            break
        if data[i] & 0xC0 == 0xC0:
            i += 2
        else:
            while i < len(data) and data[i] != 0:
                i += data[i] + 1
            i += 1
        typ, _cls, _ttl, rdlen = struct.unpack("!HHIH", data[i : i + 10])
        i += 10
        rdata = data[i : i + rdlen]
        i += rdlen
        if typ == 1 and rdlen == 4:
            return ".".join(str(b) for b in rdata)
    raise RuntimeError("no A record")


def main() -> int:
    if len(sys.argv) != 2 or not sys.argv[1].strip():
        print("usage: probe-lan-dns-a.py <fqdn>", file=sys.stderr)
        return 2
    print(query_a(sys.argv[1]))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001 - CLI probe surface
        print(str(exc), file=sys.stderr)
        raise SystemExit(1) from exc
