SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

GO ?= go
VERSION ?= dev
LDFLAGS := -X main.version=$(VERSION)

BIN_DIR := bin
ZONCTL_BIN := $(BIN_DIR)/zonctl

.PHONY: build
build:
	mkdir -p $(BIN_DIR)
	$(GO) build -ldflags "$(LDFLAGS)" -o $(ZONCTL_BIN) ./cmd/zonctl

# Normal unit tests must not require root, K3s, or network access.
.PHONY: unit-test
unit-test:
	$(GO) test ./...

.PHONY: lint
lint:
	gofmt -l -s $$(find . -name '*.go' -not -path './.git/*') | tee /tmp/appliance-gofmt.out
	test ! -s /tmp/appliance-gofmt.out
	$(GO) vet ./...

# Verifies schemas compile and every fixture validates as expected; the
# same check the unit tests run, exposed as its own gate for callers
# that only want document/schema verification. `make verify` (below)
# composes this into the full release-readiness gate.
.PHONY: verify-schemas
verify-schemas:
	$(GO) test ./internal/manifest/...

# --- Comprehensive Verification Gate ---------------------------------------
# `make verify` is the single command that exercises every mandatory
# check this repo requires before a change is considered mergeable —
# the "Before merging changes" checklist in docs/getting-started.md,
# collapsed into one target instead of several manual steps. Modeled on
# the sibling appliance-code repo's `make verify` (per-stage logging,
# fail fast with the log to inspect, clean at the end). Every stage:
#
#   1. build            — native build (cmd/zonctl compiles)
#   2. build (linux)     — GOOS=linux GOARCH=amd64 build; dev happens on
#                          macOS but the only supported target host is
#                          Ubuntu/amd64, so this is not optional
#   3. lint              — gofmt -l -s + go vet (native)
#   4. vet (linux)       — go vet under the same cross-compile target
#   5. unit tests        — go test ./... (every package, fakes only)
#   6. race tests        — go test ./... -race (concurrency-sensitive
#                          packages: internal/lifecycle, internal/redact)
#   7. schema/fixtures   — verify-schemas above
#   8. go mod tidy       — must be a no-op; a real diff means committed
#                          go.mod/go.sum have drifted from actual usage
#   9. clean             — leaves the working tree free of build/test
#                          artifacts once every check has passed
#
# Each stage's full output goes to its own log under $(VERIFY_LOG_DIR) so
# a failure points straight at what to inspect instead of scrolling back
# through a combined build log.
VERIFY_LOG_DIR         := $(CURDIR)/.run/logs
VERIFY_BUILD_LOG       := $(VERIFY_LOG_DIR)/verify-build.log
VERIFY_BUILD_LINUX_LOG := $(VERIFY_LOG_DIR)/verify-build-linux.log
VERIFY_LINT_LOG        := $(VERIFY_LOG_DIR)/verify-lint.log
VERIFY_VET_LINUX_LOG   := $(VERIFY_LOG_DIR)/verify-vet-linux.log
VERIFY_TEST_LOG        := $(VERIFY_LOG_DIR)/verify-test.log
VERIFY_RACE_LOG        := $(VERIFY_LOG_DIR)/verify-race.log
VERIFY_SCHEMAS_LOG     := $(VERIFY_LOG_DIR)/verify-schemas.log
VERIFY_MODTIDY_LOG     := $(VERIFY_LOG_DIR)/verify-modtidy.log

.PHONY: verify
verify:
	@set -e; \
	mkdir -p "$(VERIFY_LOG_DIR)"; \
	echo "verify stage: build (native)"; \
	if ! $(MAKE) --no-print-directory build >"$(VERIFY_BUILD_LOG)" 2>&1; then \
		echo "verify: build (native) failed; inspect $(VERIFY_BUILD_LOG)"; \
		exit 1; \
	fi; \
	echo "verify stage: build (native) passed"; \
	echo "verify stage: build (linux/amd64 cross-compile)"; \
	if ! GOOS=linux GOARCH=amd64 $(GO) build ./... >"$(VERIFY_BUILD_LINUX_LOG)" 2>&1; then \
		echo "verify: build (linux/amd64) failed; inspect $(VERIFY_BUILD_LINUX_LOG)"; \
		exit 1; \
	fi; \
	echo "verify stage: build (linux/amd64 cross-compile) passed"; \
	echo "verify stage: lint (gofmt + go vet, native)"; \
	if ! $(MAKE) --no-print-directory lint >"$(VERIFY_LINT_LOG)" 2>&1; then \
		echo "verify: lint failed; inspect $(VERIFY_LINT_LOG)"; \
		exit 1; \
	fi; \
	echo "verify stage: lint passed"; \
	echo "verify stage: go vet (linux/amd64 cross-compile)"; \
	if ! GOOS=linux GOARCH=amd64 $(GO) vet ./... >"$(VERIFY_VET_LINUX_LOG)" 2>&1; then \
		echo "verify: go vet (linux/amd64) failed; inspect $(VERIFY_VET_LINUX_LOG)"; \
		exit 1; \
	fi; \
	echo "verify stage: go vet (linux/amd64 cross-compile) passed"; \
	echo "verify stage: unit tests"; \
	if ! $(MAKE) --no-print-directory unit-test >"$(VERIFY_TEST_LOG)" 2>&1; then \
		echo "verify: unit tests failed; inspect $(VERIFY_TEST_LOG)"; \
		exit 1; \
	fi; \
	echo "verify stage: unit tests passed"; \
	echo "verify stage: race-detector tests"; \
	if ! $(GO) test ./... -race >"$(VERIFY_RACE_LOG)" 2>&1; then \
		echo "verify: race-detector tests failed; inspect $(VERIFY_RACE_LOG)"; \
		exit 1; \
	fi; \
	echo "verify stage: race-detector tests passed"; \
	echo "verify stage: schema/fixture validation"; \
	if ! $(MAKE) --no-print-directory verify-schemas >"$(VERIFY_SCHEMAS_LOG)" 2>&1; then \
		echo "verify: schema/fixture validation failed; inspect $(VERIFY_SCHEMAS_LOG)"; \
		exit 1; \
	fi; \
	echo "verify stage: schema/fixture validation passed"; \
	echo "verify stage: go mod tidy (no dependency drift)"; \
	cp go.mod "$(VERIFY_LOG_DIR)/go.mod.snapshot"; \
	cp go.sum "$(VERIFY_LOG_DIR)/go.sum.snapshot"; \
	if ! $(GO) mod tidy >"$(VERIFY_MODTIDY_LOG)" 2>&1; then \
		cp "$(VERIFY_LOG_DIR)/go.mod.snapshot" go.mod; \
		cp "$(VERIFY_LOG_DIR)/go.sum.snapshot" go.sum; \
		echo "verify: go mod tidy failed; inspect $(VERIFY_MODTIDY_LOG)"; \
		exit 1; \
	fi; \
	if cmp -s "$(VERIFY_LOG_DIR)/go.mod.snapshot" go.mod && cmp -s "$(VERIFY_LOG_DIR)/go.sum.snapshot" go.sum; then \
		echo "verify stage: go mod tidy passed (no drift)"; \
	else \
		cp "$(VERIFY_LOG_DIR)/go.mod.snapshot" go.mod; \
		cp "$(VERIFY_LOG_DIR)/go.sum.snapshot" go.sum; \
		echo "verify: go mod tidy found drift in go.mod/go.sum — run 'go mod tidy' locally, review the diff, and commit the result"; \
		exit 1; \
	fi; \
	echo "verify stage: clean"; \
	$(MAKE) --no-print-directory clean >/dev/null 2>&1; \
	echo "verify stage: clean passed"; \
	echo "verify: all mandatory checks passed"

# --- Privileged/VM lanes below are explicit, separately gated targets.
# The Go logic behind each of these (preflight checks, the lifecycle CLI,
# install/upgrade/backup/restore/uninstall orchestration) is implemented
# and covered by `make unit-test` against fakes. These targets are for
# running the *same* commands for real against a live host/VM with a
# real K3s and a real assembled bundle. The VM harness targets are still
# explicit/manual, but bundle assembly and verification are implemented
# below so operators can produce and inspect a signed extracted bundle.

.PHONY: test-preflight
test-preflight:
	@echo "test-preflight: no VM harness wired up yet to run 'appliance preflight' against a real host" >&2
	@exit 1

.PHONY: test-installer
test-installer:
	@echo "test-installer: no VM harness wired up yet to run the lifecycle CLI against a real host" >&2
	@exit 1

.PHONY: assemble-bundle
assemble-bundle:
	@if [ -z "$${BUNDLE_CONFIG:-}" ]; then \
		echo "assemble-bundle: set BUNDLE_CONFIG=/abs/path/to/bundle-assembly.json" >&2; \
		exit 2; \
	fi
	$(GO) run ./cmd/zonctl assemble-bundle --config "$${BUNDLE_CONFIG}"

.PHONY: verify-bundle
verify-bundle:
	@if [ -z "$${BUNDLE_DIR:-}" ] || [ -z "$${PUBLIC_KEY:-}" ]; then \
		echo "verify-bundle: set BUNDLE_DIR=/abs/path/to/bundle and PUBLIC_KEY=/abs/path/to/release-signing.pub" >&2; \
		exit 2; \
	fi
	$(GO) run ./cmd/zonctl verify-bundle --bundle-dir "$${BUNDLE_DIR}" --public-key "$${PUBLIC_KEY}"

.PHONY: test-install-airgap
test-install-airgap:
	@echo "test-install-airgap: no egress-denied VM harness wired up yet; 'appliance install' itself is implemented, see docs/install.md" >&2
	@exit 1

.PHONY: test-upgrade
test-upgrade:
	@echo "test-upgrade: no VM harness wired up yet; 'appliance upgrade' itself is implemented, see docs/upgrade.md" >&2
	@exit 1

.PHONY: test-restore
test-restore:
	@echo "test-restore: no VM harness wired up yet; 'appliance backup/restore' itself is implemented, see docs/backup-restore.md" >&2
	@exit 1

.PHONY: test-uninstall
test-uninstall:
	@echo "test-uninstall: no VM harness wired up yet; 'appliance uninstall/factory-reset' itself is implemented" >&2
	@exit 1

# Removes every artifact this repo's own tooling can leave behind in the
# working tree: the built binary, `make verify`'s own log directory, and
# any stray Go test binaries/coverage files a developer's ad hoc
# `go test -c`/`-cover` run may have dropped next to a package (the
# normal `make unit-test`/`make lint`/`make verify` targets don't produce
# these themselves — every test uses t.TempDir(), which Go cleans up on
# its own outside the repo tree — but this sweeps for them defensively
# since nothing here should ever need to survive a clean). Matches the
# patterns already in .gitignore.
.PHONY: clean
clean:
	rm -rf $(BIN_DIR) $(VERIFY_LOG_DIR)
	find . -not -path './.git/*' \( \
		-name '*.test' -o \
		-name '*.out' -o \
		-name 'coverage.*' -o \
		-name '*.coverprofile' -o \
		-name 'profile.cov' \
	\) -delete
