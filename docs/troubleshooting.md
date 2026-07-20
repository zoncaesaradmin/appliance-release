# Troubleshooting Reference

## Runtime service logs

The appliance is moving toward one fixed runtime log root on the target host:

```text
/data/zon/logs
```

For the currently migrated always-running Go services, check:

```text
/data/zon/logs/control-plane/
/data/zon/logs/ui/
/data/zon/logs/argo-controller/
```

Each service directory is expected to contain:

```text
stdout.log
stderr.log
application.log
```

Startup banners are folded into `stdout.log`; functional service flow logs are
written to `application.log`.

Service log directories are expected to be readable/traversable by the target
host operator while remaining writable only by the owning service UID. If a
directory shows mode `2770` and a normal operator user cannot `cd` into it,
the deployed chart is older than the operator-readable log-directory policy.

Kubernetes-native log access is still valid and remains important:

```bash
sudo kubectl -n appliance-system logs deploy/control-plane
sudo kubectl -n appliance-system logs deploy/control-plane-ui
sudo kubectl -n workflows logs deploy/argo-workflows
sudo kubectl -n appliance-builds logs <pod-name>
sudo journalctl -u k3s -f
```

## `zonctl status`

Reports installed version and K3s health:

```
zonctl status --output json --state-dir /var/lib/zon/state
```

The command itself reports `"status": "succeeded"` even when the
dependency it's reporting on is unhealthy — a bad verdict is a legitimate,
correctly-produced answer, not a command failure. Check the exit code
(non-zero when unhealthy) or `data.k3sHealthy` / `data.componentHealth`
for the actual verdict.

## `zonctl verify`

Re-checks installed-state's own validity and current K3s health, reporting
`data.manifestValid`, `data.entriesVerified`, and `data.entriesFailed`.

Re-verifying every installed artifact's digest against the original
release manifest (not just installed-state's own schema validity) requires
retaining that manifest past install time, which is not yet wired up —
today `verify` checks installed-state's integrity and current K3s health,
not a full artifact-by-artifact re-verification. This is a known gap.

## `zonctl repair`

The only remediation `repair` performs is restarting K3s when
installed-state records it as owned but the service isn't currently
active:

- **Owned and stopped** → restarts it.
- **Owned and already active** → no-op, reports success.
- **Owned but the service is missing entirely** (not just stopped) →
  refuses; this needs `restore`, not `repair`.
- **Nothing installed** → refuses; run `install` first.

`repair` is also the one mutating command allowed to proceed when the
transaction journal shows an interrupted prior operation — every other
mutating command blocks with a message pointing at `repair` until it runs.

## `zonctl support-bundle`

Collects `installed-state.json` (if present), a fresh diagnostics
snapshot, and every previously persisted `evidence.v1` report under
`<state-dir>/evidence/` into a single `tar.gz`, with every registered
secret scrubbed before anything is written (see
[security.md](security.md#redaction)). The result's `data.digest` is the
SHA-256 of the archive itself, so its integrity can be checked
independently of transport.

## "a prior operation did not complete"

Every mutating command reads the transaction journal before doing
anything. If the last recorded transaction never reached a terminal
status (the process died mid-operation), every command except `repair`
refuses with a message naming the interrupted transaction and operation
type. Run `zonctl repair`, or investigate the crash's cause, before
retrying the original command.

## "requires-force-adopt"

See [security.md](security.md#k3s-ownership). This means `zonctl` found
an existing K3s cluster it didn't create, and either couldn't confirm the
cluster is healthy or found workloads outside `kube-system`/the platform
namespace. Investigate the cluster before proceeding — if it's genuinely
safe to take over, re-run with `--force-adopt`.
