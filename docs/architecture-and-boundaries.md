# Architecture And Boundaries

This page is the short current-state architecture reference for
`appliance-release`. For the historical full execution plan and ledger, see
[archive/release-plan.md](archive/release-plan.md).

## Purpose

This repository turns one signed, immutable product input set into one complete
air-gapped Linux appliance bundle that an operator can install, upgrade,
repair, back up, restore, diagnose, and safely remove without public internet
access.

It is a distribution and lifecycle repository. It does not contain or rebuild
private application source.

## Accepted Direction

- A newly signed appliance release requires exactly one or three active, schedulable
  K3s servers with embedded etcd. There are no agents, dedicated workers, or
  one-server-plus-two-agent production layouts.
- The operator provides one or three direct server IPv4 addresses at install time.
  Each serves the Kubernetes API; clients retry another address after a node
  failure. The Kubernetes milestone has no floating address or mandatory load
  balancer.
- The appliance name and selected profile identify the cluster, not an
  individual host. Product application placement and durable storage remain a
  separate application-HA qualification: Kubernetes HA must not be presented
  as a product-HTTPS availability claim.
- Legacy prime/member records and commands remain only for reading, export,
  and migration of older releases. They are not a new-install option.
- the only production install path is the signed air-gap bundle
- installation and runtime must work with public egress denied
- the installer is manifest-driven rather than hardcoded
- K3s ownership never silently takes over a cluster with unrelated workloads.
  The one- or three-server release stages an empty, inventory-matched host.
  A release-owned K3s unit that is not active and has no bootstrap receipt is
  stopped and its data directory removed so that stage can start clean. An
  active service, or a unit this release did not write, stays in place.
  Qualifying adoption or migration of an existing cluster is a separate,
  explicit recovery workflow.
- versioning is two-tier:
  platform version plus independent per-service versions

## Repository Boundary

| Owned here | Supplied by `appliance-code` |
| --- | --- |
| Host detection, preflight, and safe remediation | Control-plane OCI image |
| K3s installation, configuration, pinning, and lifecycle | Canonical appliance Helm chart and values schema |
| Final release manifest and bundle assembly | Compatibility tuple and immutable product inputs |
| Installer, upgrader, repair, backup, restore, diagnostics, and uninstall UX | Migration compatibility and application lifecycle hooks |
| Public support and verification docs | Product SBOMs, provenance, notices, signatures, and compatibility evidence |

The release pipeline may reject a product input but cannot patch it.

## Release Shape

Production packaging always assembles the **complete product super-set** (all
first-class OCI images, the workflows engine, host packages for mdns + wifi-client + wifi-ap, workspace
provisioner + builder `dev-build`). Profile and host-service flags are
install-time only. Component inventory and named stages:
[component-catalog.md](component-catalog.md).

The bundle contains:

- the `zonctl` appliance CLI
- K3s binary and air-gap payload
- application OCI images
- bundled helper binaries such as `helm`, `kubectl`, and `ctr`
- the product Helm chart
- configuration
- signed `release-manifest.json` and `release-manifest.sig`

Install preloads deployment images into the local K3s image store before any
appliance pod starts. The appliance's own artifact registry is not part of
bootstrap trust.

## Lifecycle Contract

For a current signed embedded-etcd release, the public install sequence is:

- `zonctl cluster-server-stage` on the bootstrap and, for a three-server inventory, each peer
- `zonctl cluster-server-enrollment-create` for each peer in a three-server inventory
- `zonctl cluster-finalize` once every planned server has joined
- `zonctl cluster-ha-check`, `zonctl status`, `zonctl verify`, and
  `zonctl support-bundle` for read-only health and diagnostics

Until the coordinated etcd lifecycle is qualified, mutating local-host
commands (`backup`, `restore`, `upgrade`, `repair`, and `uninstall`) fail
closed for this topology. `factory-reset` is allowed only when the installed
receipt lists exactly one embedded-etcd server; a three-server receipt and a
staged peer still fail closed. Older `install`,
prime/member enrollment, and worker commands are legacy migration surfaces,
not alternate deployment modes.

## Current Documentation Split

- developer / build flow:
  [developer-guide.md](developer-guide.md)
- target host / operator flow:
  [operator-guide.md](operator-guide.md)
- artifact capability:
  [artifact-registry.md](artifact-registry.md)
- DNS capability:
  [lan-dns.md](lan-dns.md)
- trust, ownership, and offline rules:
  [security-model.md](security-model.md)
