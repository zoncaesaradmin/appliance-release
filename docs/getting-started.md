# Getting Started

This page is for two different audiences, because this repository is
mid-build (see [CHANGELOG.md](../CHANGELOG.md)): an **operator** who
eventually runs `zonctl install` against a real signed bundle, and a
**developer** working on this repository itself. Read the section that
matches what you're trying to do.

## For Operators: Installing Zon

On a supported Ubuntu Server host (22.04 or 24.04 LTS), installing Zon is
one command from the signed appliance bundle:

```
zonctl install --bundle-dir /path/to/extracted/bundle --public-key /path/to/release-signing.pub
```

`zonctl` verifies the signed bundle, re-checks every artifact digest,
runs host preflight, installs and starts K3s (or adopts a compatible
existing cluster), preloads the bundled images, and applies the chart —
see [install.md](install.md) for
exactly what happens at each step.

Public egress is not required during install or runtime.

## For Developers: Working On This Repository

### Prerequisites

- Go 1.24+ (`go.mod` pins the toolchain version)
- `make`
- macOS or Linux to build and run unit tests. Only Linux gets the real
  host-detection, K3s-service, and OCI/Helm adapters — on macOS those
  adapters fall back to safe no-op stubs so the code still builds and
  tests still run (see the `internal/host`, `internal/k3s` build-tagged
  files), but you won't get real preflight or service results locally.

### Day-to-day loop

```
make build          # compiles cmd/zonctl to bin/zonctl
make unit-test       # go test ./... — no root, no K3s, no network required
make lint            # gofmt -l -s + go vet
make verify-schemas  # schema/fixture validation only (a subset of unit-test)
make clean           # remove bin/, make verify's logs, and any stray test/coverage artifacts
```

Use these individually while iterating — `make unit-test` is the
fastest inner-loop check, running all 135+ tests across every package.

### `make verify`: the single pre-merge gate

`make verify` composes everything above into one command and is what you
should actually run before merging or opening a PR — see "Before merging
changes" below. It runs, in order, until the first failure: native build,
`GOOS=linux GOARCH=amd64` build (the only supported target host is
Ubuntu/amd64, even though development happens on macOS), lint, `GOOS=linux
GOARCH=amd64 go vet`, unit tests, `go test ./... -race` (the
race-detector-clean concurrency tests in `internal/lifecycle` and
`internal/redact`), schema/fixture validation, a `go mod tidy` no-op
check, and finally `make clean`. Each stage's full output is logged to
its own file under `.run/logs/` (gitignored), so a failure points
straight at what to inspect instead of scrolling back through one
combined log — the failing stage's message names the exact log path.
`make clean` at the end means a passing `make verify` always leaves the
working tree free of build/test artifacts, not just the code checked out.

### Real-bundle and VM targets

`assemble-bundle` and `verify-bundle` are now real targets. They use
`zonctl` directly for producing and verifying a signed extracted bundle:

```bash
BUNDLE_CONFIG=/abs/path/to/bundle-assembly.json make assemble-bundle
BUNDLE_DIR=/abs/path/to/bundle PUBLIC_KEY=/abs/path/to/release-signing.pub make verify-bundle
```

The remaining host/VM lanes still intentionally fail today:

- `test-preflight`
- `test-installer`
- `test-install-airgap`
- `test-upgrade`
- `test-restore`
- `test-uninstall`

Those are still placeholders for privileged real-host automation. The
underlying lifecycle logic each one represents **is** implemented and
covered by `make unit-test`; only the fully automated live-host harness
is still missing.

### Exercising the CLI without a real product bundle

You can build and run `zonctl` against a small hand-built fixture
bundle to see the full flow without needing a real `appliance-code`
product input. This mirrors what `internal/install/install_test.go`'s
fixture builder does automatically for tests; the same shape works from a
shell:

```
make build
mkdir -p /tmp/fixture-bundle
# ...write release-manifest.json, release-manifest.sig, and the files it
# references (see internal/bundle/bundle_test.go for the exact shape and
# internal/verify for how to generate an ed25519 keypair and sign it)
./bin/zonctl install --bundle-dir /tmp/fixture-bundle --public-key /tmp/release-signing.pub --state-dir /tmp/zon-state
```

On a non-Linux machine this will get past bundle verification and
preflight (if the fixture host facts pass) and then fail at the K3s
service step, since there's no real `systemctl`/K3s to drive — that's
expected. `zonctl preflight --output json` and `zonctl status
--output json` work standalone on any machine and are the fastest way to
see real command output without building a fixture bundle at all.

### Before merging changes

1. `make verify` — must pass. This single command is every check listed
   above (build, cross-compile, lint, unit tests, race tests,
   schema/fixture validation, `go mod tidy` drift check) plus a final
   `make clean`; nothing else needs to be run separately.
2. If you touched a schema in `schemas/`, add or update fixtures under
   `tests/fixtures/` — every schema change should be paired with at
   least one valid and one invalid fixture — then `make verify` (or
   `make verify-schemas` alone, while iterating) confirms they pass.
3. Everything in this repository as of this writing is uncommitted on
   `main` on top of a single "Initial commit" — there is no open PR yet.
   Review the diff, then commit or open a PR through your normal process;
   nothing here commits or pushes on your behalf.
