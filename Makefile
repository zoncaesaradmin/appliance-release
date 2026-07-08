SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

DEFAULT_ZONCTL_BINARY := $(CURDIR)/../appliance-ctl/bin/zonctl
ZONCTL_BINARY ?= $(DEFAULT_ZONCTL_BINARY)
VERIFY_LOG_DIR := $(CURDIR)/.run/logs
VERIFY_SHELL_LOG := $(VERIFY_LOG_DIR)/verify-shell.log
VERIFY_HELP_LOG := $(VERIFY_LOG_DIR)/verify-help.log
VERIFY_JSON_LOG := $(VERIFY_LOG_DIR)/verify-json.log

.PHONY: verify-shell
verify-shell:
	@bash -n $$(find scripts -type f -name '*.sh' | LC_ALL=C sort)
	@bash -n configs/product-bundle.sample.env
	@bash -n configs/product-bundle.ci.env

.PHONY: verify-help
verify-help:
	@for script in $$(find scripts -type f -name '*.sh' | LC_ALL=C sort); do \
		bash "$$script" --help >/dev/null; \
	done

.PHONY: verify-json
verify-json:
	@python3 -c 'import json; from pathlib import Path; [json.load(path.open("r", encoding="utf-8")) for path in sorted(Path("docs").rglob("*.json"))]'

.PHONY: verify
verify:
	@set -e; \
	mkdir -p "$(VERIFY_LOG_DIR)"; \
	echo "verify stage: shell syntax"; \
	if ! $(MAKE) --no-print-directory verify-shell >"$(VERIFY_SHELL_LOG)" 2>&1; then \
		echo "verify: shell syntax failed; inspect $(VERIFY_SHELL_LOG)"; \
		exit 1; \
	fi; \
	echo "verify stage: shell syntax passed"; \
	echo "verify stage: script help smoke"; \
	if ! $(MAKE) --no-print-directory verify-help >"$(VERIFY_HELP_LOG)" 2>&1; then \
		echo "verify: script help smoke failed; inspect $(VERIFY_HELP_LOG)"; \
		exit 1; \
	fi; \
	echo "verify stage: script help smoke passed"; \
	echo "verify stage: JSON examples"; \
	if ! $(MAKE) --no-print-directory verify-json >"$(VERIFY_JSON_LOG)" 2>&1; then \
		echo "verify: JSON examples failed; inspect $(VERIFY_JSON_LOG)"; \
		exit 1; \
	fi; \
	echo "verify stage: JSON examples passed"; \
	echo "verify stage: clean"; \
	$(MAKE) --no-print-directory clean >/dev/null 2>&1; \
	echo "verify stage: clean passed"; \
	echo "verify: all local checks passed"

.PHONY: assemble-bundle
assemble-bundle:
	@if [ -z "$${BUNDLE_CONFIG:-}" ]; then \
		echo "assemble-bundle: set BUNDLE_CONFIG=/abs/path/to/bundle-assembly.json" >&2; \
		exit 2; \
	fi
	@if [ ! -x "$(ZONCTL_BINARY)" ]; then \
		echo "assemble-bundle: missing zonctl binary at $(ZONCTL_BINARY)" >&2; \
		echo "build appliance-ctl first or set ZONCTL_BINARY=/abs/path/to/zonctl" >&2; \
		exit 1; \
	fi
	"$(ZONCTL_BINARY)" assemble-bundle --config "$${BUNDLE_CONFIG}"

.PHONY: init-simple-workspace
init-simple-workspace:
	@if [ -z "$${WORKDIR:-}" ]; then \
		echo "init-simple-workspace: set WORKDIR=/abs/path/to/workspace" >&2; \
		exit 2; \
	fi
	bash ./scripts/package/init-simple-workspace.sh \
		--workdir "$${WORKDIR}" \
		--zonctl-binary "$${ZONCTL_BINARY:-$(ZONCTL_BINARY)}" \
		$${PRODUCT_VERSION:+--product-version "$${PRODUCT_VERSION}"} \
		$${CONTROL_PLANE_IMAGE_REF:+--control-plane-image-ref "$${CONTROL_PLANE_IMAGE_REF}"} \
		$${OS_VERSION:+--os-version "$${OS_VERSION}"}

.PHONY: fetch-release-input
fetch-release-input:
	@if [ -z "$${WORKDIR:-}" ]; then \
		echo "fetch-release-input: set WORKDIR=/abs/path/to/workspace" >&2; \
		exit 2; \
	fi
	@if [ -z "$${RELEASE_INPUT_SOURCE:-}" ] && { [ -z "$${RELEASE_INPUT_VERSION:-}" ] || [ -z "$${RELEASE_INPUT_FETCH_TEMPLATE:-}" ]; }; then \
		echo "fetch-release-input: set RELEASE_INPUT_SOURCE=/path-or-url or both RELEASE_INPUT_VERSION=... and RELEASE_INPUT_FETCH_TEMPLATE=..." >&2; \
		exit 2; \
	fi
	bash ./scripts/package/fetch-release-input.sh \
		--workdir "$${WORKDIR}" \
		$${RELEASE_INPUT_SOURCE:+--source "$${RELEASE_INPUT_SOURCE}"} \
		$${RELEASE_INPUT_VERSION:+--version "$${RELEASE_INPUT_VERSION}"} \
		$${RELEASE_INPUT_FETCH_TEMPLATE:+--template "$${RELEASE_INPUT_FETCH_TEMPLATE}"}

.PHONY: assemble-simple-bundle
assemble-simple-bundle:
	@if [ -z "$${WORKDIR:-}" ]; then \
		echo "assemble-simple-bundle: set WORKDIR=/abs/path/to/workspace" >&2; \
		exit 2; \
	fi
	bash ./scripts/package/assemble-simple-bundle.sh \
		--workdir "$${WORKDIR}" \
		--zonctl-binary "$${ZONCTL_BINARY:-$(ZONCTL_BINARY)}"

.PHONY: product-bundle
product-bundle:
	@if [ -z "$${CONFIG:-}" ]; then \
		echo "product-bundle: set CONFIG=/abs/path/to/product-bundle.env" >&2; \
		exit 2; \
	fi
	bash ./scripts/package/product-bundle-from-config.sh --config "$${CONFIG}"

.PHONY: verify-bundle
verify-bundle:
	@if [ -z "$${BUNDLE_DIR:-}" ] || [ -z "$${PUBLIC_KEY:-}" ]; then \
		echo "verify-bundle: set BUNDLE_DIR=/abs/path/to/bundle and PUBLIC_KEY=/abs/path/to/release-signing.pub" >&2; \
		exit 2; \
	fi
	@if [ ! -x "$(ZONCTL_BINARY)" ]; then \
		echo "verify-bundle: missing zonctl binary at $(ZONCTL_BINARY)" >&2; \
		echo "build appliance-ctl first or set ZONCTL_BINARY=/abs/path/to/zonctl" >&2; \
		exit 1; \
	fi
	"$(ZONCTL_BINARY)" verify-bundle --bundle-dir "$${BUNDLE_DIR}" --public-key "$${PUBLIC_KEY}"

.PHONY: publish-release
publish-release:
	@if [ -z "$${PUBLISH_MODE:-}" ] || [ -z "$${EXPORT_DIR:-}" ] || [ -z "$${PRODUCT_VERSION:-}" ]; then \
		echo "publish-release: set PUBLISH_MODE=..., EXPORT_DIR=/abs/path/to/export, and PRODUCT_VERSION=..." >&2; \
		exit 2; \
	fi
	bash ./scripts/publish/publish-release.sh \
		--mode "$${PUBLISH_MODE}" \
		--export-dir "$${EXPORT_DIR}" \
		--product-version "$${PRODUCT_VERSION}" \
		$${PUBLISH_SERVER:+--server "$${PUBLISH_SERVER}"} \
		$${PUBLISH_REMOTE_ROOT:+--remote-root "$${PUBLISH_REMOTE_ROOT}"} \
		$${PUBLISH_PATH_PREFIX:+--path-prefix "$${PUBLISH_PATH_PREFIX}"} \
		$${PUBLISH_SSH_PORT:+--ssh-port "$${PUBLISH_SSH_PORT}"} \
		$${PUBLISH_PUBLIC_BASE_URL:+--public-base-url "$${PUBLISH_PUBLIC_BASE_URL}"} \
		$${PUBLISH_LATEST_ALIAS:+--latest-alias}

.PHONY: fetch-http-release
fetch-http-release:
	@if [ -z "$${FETCH_BASE_URL:-}" ] || [ -z "$${PRODUCT_VERSION:-}" ] || [ -z "$${FETCH_OUT_DIR:-}" ]; then \
		echo "fetch-http-release: set FETCH_BASE_URL=..., PRODUCT_VERSION=..., and FETCH_OUT_DIR=/abs/path/to/download-dir" >&2; \
		exit 2; \
	fi
	bash ./scripts/publish/fetch-http-release.sh \
		--base-url "$${FETCH_BASE_URL}" \
		--product-version "$${PRODUCT_VERSION}" \
		--out-dir "$${FETCH_OUT_DIR}" \
		$${FETCH_PATH_PREFIX:+--path-prefix "$${FETCH_PATH_PREFIX}"} \
		$${FETCH_USE_LATEST:+--use-latest}

.PHONY: clean
clean:
	rm -rf bin .run
