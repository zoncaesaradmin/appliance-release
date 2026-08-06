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

- V1 supports a dedicated single-node Linux appliance with product-managed K3s
- the only production install path is the signed air-gap bundle
- installation and runtime must work with public egress denied
- the installer is manifest-driven rather than hardcoded
- K3s ownership allows safe adoption of an existing K3s cluster, but never
  silently takes over a cluster with unrelated workloads
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
first-class OCI images, the workflows engine, host packages for mdns + wifi-ap, workspace
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

The public lifecycle surface is centered on:

- `zonctl preflight`
- `zonctl install`
- `zonctl status`
- `zonctl verify`
- `zonctl backup`
- `zonctl restore`
- `zonctl upgrade`
- `zonctl repair`
- `zonctl support-bundle`
- `zonctl uninstall`
- `zonctl factory-reset`

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
