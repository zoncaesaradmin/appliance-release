# Offline Verification Reference

Every verification step described here runs entirely against local files
and requires no network access — that's a hard invariant of this
repository (see [security.md](security.md#offline-operation)), not just
this guide's recommendation.

## Storage and builder artifact evidence

Storage is a positive artifact-service profile, not merely a negative builder
profile. Target verification waits for the zot Deployment and dedicated PVC.
Client verification checks the profile-gated catalog route, `/v2/` bearer
challenge, API-token-backed registry token issuance, filtered catalog access,
and anonymous, denied-scope, malformed-token, and token-revocation behavior.

Builder requires the same artifact evidence in addition to builder workflow
evidence; core requires artifact routes to remain absent. Optional OCI,
ORAS/referrer, and offline smoke commands under
`client_verification.artifact` must pass when configured. Credentials are
provided only through process-local `APPLIANCE_REGISTRY_*` variables.

## Verifying a Bundle Before Installing

`zonctl install` and `zonctl upgrade` already perform every check
below automatically and fail closed if any of them don't pass. This
section is for an operator who wants to verify a bundle independently,
before trusting it to the installer — for example, immediately after
transferring it across an air gap.

### 1. Verify the release manifest's signature

The bundle ships `release-manifest.json` and a detached signature
`release-manifest.sig`, both signed with the release-signing key whose
public half you should already have out-of-band (see
[security.md](security.md#verification-chain) — this key is the root of
trust and must be obtained independently of the bundle itself).

Using `openssl` against a raw ed25519 public key in PEM form:

```
openssl pkeyutl -verify \
  -pubin -inkey release-signing.pub \
  -rawin -in release-manifest.json \
  -sigfile release-manifest.sig
```

`zonctl` performs the equivalent check with
`internal/verify.VerifyFileSignature` against the same PEM-encoded key.

### 2. Verify every artifact's digest

Once the manifest itself is trusted, every file it lists must match its
recorded digest and size. Each entry in `release-manifest.json`'s
`entries` array has `path`, `digest` (`sha256:<hex>`), and `sizeBytes`.
For any entry:

```
sha256sum <bundle-root>/<entry.path>
```

...and compare the output to the entry's `digest` field (drop the
`sha256:` prefix). `zonctl` does this for every entry automatically via
`internal/verify.VerifyArtifacts`; a single mismatched file fails the
whole bundle closed.

### 3. Confirm no network access is required

Installation is designed to require zero network access, and this is
tested directly — several packages (`internal/verify`, `internal/images`,
`internal/helm`, `internal/install`) include an automated test that blocks
DNS resolution entirely and confirms the relevant operation still
succeeds. An operator can verify this independently by installing with
public egress blocked at the network layer (firewall rule or disconnected
NIC) and confirming `zonctl install` still completes.

## Verifying an Installed Host

`zonctl verify` re-checks `installed-state.json`'s own validity and
current K3s health (see [troubleshooting.md](troubleshooting.md#zonctl-verify)
for the current scope of this check). `zonctl status` reports the same
health signals in a form meant for routine monitoring rather than a
one-time integrity check.

## Verifying a Support Bundle

`zonctl support-bundle`'s result includes `data.digest`, the SHA-256 of
the produced archive itself:

```
sha256sum <bundle-path>
```

Compare against `data.digest` to confirm the archive was not altered in
transit after `zonctl` produced it.
