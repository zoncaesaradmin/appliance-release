SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

DEFAULT_ZONCTL_BINARY := $(CURDIR)/../appliance-ctl/bin/zonctl
ZONCTL_BINARY ?= $(DEFAULT_ZONCTL_BINARY)
VERIFY_LOG_DIR := $(CURDIR)/.run/logs
VERIFY_SHELL_LOG := $(VERIFY_LOG_DIR)/verify-shell.log
VERIFY_HELP_LOG := $(VERIFY_LOG_DIR)/verify-help.log
VERIFY_JSON_LOG := $(VERIFY_LOG_DIR)/verify-json.log
VERIFY_CLIENT_CONFIG_LOG := $(VERIFY_LOG_DIR)/verify-client-config.log
VERIFY_CLIENT_CONFIG_CASE_LOG := $(VERIFY_LOG_DIR)/verify-client-config-case.log
VERIFY_RELEASE_ARTIFACTS_LOG := $(VERIFY_LOG_DIR)/verify-release-artifacts.log
RELEASE_SKILL_SCRIPT_DIR := .agents/skills/release/scripts

.PHONY: verify-shell
verify-shell:
	@bash -n $$(find scripts -type f -name '*.sh' | LC_ALL=C sort)
	@bash -n $$(find "$(RELEASE_SKILL_SCRIPT_DIR)" -type f -name '*.sh' | LC_ALL=C sort)
	@bash -n configs/product-bundle.sample.env
	@bash -n configs/product-bundle.ci.env
	@PYTHONPYCACHEPREFIX="$(CURDIR)/.run/pycache" python3 -m py_compile $$(find "$(RELEASE_SKILL_SCRIPT_DIR)" -type f -name '*.py' | LC_ALL=C sort)

.PHONY: verify-help
verify-help:
	@for script in $$(find scripts -type f -name '*.sh' | LC_ALL=C sort); do \
		bash "$$script" --help >/dev/null; \
	done
	@for script in $$(find "$(RELEASE_SKILL_SCRIPT_DIR)" -type f -name '*.sh' | LC_ALL=C sort); do \
		bash "$$script" --help >/dev/null; \
	done
	@bash scripts/publish/install-http-release.sh --help | grep -q -- '--appliance-name'
	@bash scripts/publish/install-http-release.sh --help | grep -q -- 'BUILD_CATALOG_PATH'
	@bash scripts/publish/publish-release.sh --help | grep -q -- '--mode'
	@bash scripts/publish/publish-release.sh --help | grep -q -- 'appliance_files'
	@bash scripts/publish/bundle-store-lib.sh --help | grep -q -- 'appliance_files'

.PHONY: verify-json
verify-json:
	@python3 -c 'import json; from pathlib import Path; [json.load(path.open("r", encoding="utf-8")) for path in sorted(Path("docs").rglob("*.json"))]'

.PHONY: verify-client-config
verify-client-config:
	@mkdir -p "$(VERIFY_LOG_DIR)"
	@config_file="$(VERIFY_LOG_DIR)/client-invalid-source-ref.yaml"; \
	run_dir="$(VERIFY_LOG_DIR)/client-invalid-source-ref-run"; \
	printf '%s\n' \
		'install:' \
		'  appliance_profile: core' \
		'client_verification:' \
		'  builder:' \
		'    workflow:' \
		'      enabled: true' \
		'      workspace_name: release-smoke' \
		'      work_profile: builder' \
		'      repo: app' \
		'      source_ref: main' \
		'      target_name: app' \
		> "$$config_file"; \
	set +e; \
	APPLIANCE_FIRST_ADMIN_PASSWORD=test bash "$(RELEASE_SKILL_SCRIPT_DIR)/verify-client-access.sh" --config "$$config_file" --run-dir "$$run_dir" --appliance-profile builder >"$(VERIFY_CLIENT_CONFIG_CASE_LOG)" 2>&1; \
	status="$$?"; \
	set -e; \
	if [ "$$status" -eq 0 ]; then \
		echo "verify-client-config: mutable source_ref was accepted"; \
		exit 1; \
	fi; \
	grep -q 'source_ref must be a 40-character lowercase commit SHA' "$(VERIFY_CLIENT_CONFIG_CASE_LOG)"

.PHONY: verify-release-artifacts
verify-release-artifacts:
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_validate_release_artifacts.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_validate_build_catalog.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_summarize_release_run.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_verify_client_access.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_live_release_repo_preflight.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_build_and_publish_config.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_bundle_store_mode.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_appliance_files_bundle_store.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_shell_quote_env.py"

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
	echo "verify stage: client config validation"; \
	if ! $(MAKE) --no-print-directory verify-client-config >"$(VERIFY_CLIENT_CONFIG_LOG)" 2>&1; then \
		echo "verify: client config validation failed; inspect $(VERIFY_CLIENT_CONFIG_LOG)"; \
		exit 1; \
	fi; \
	echo "verify stage: client config validation passed"; \
	echo "verify stage: release artifact validation"; \
	if ! $(MAKE) --no-print-directory verify-release-artifacts >"$(VERIFY_RELEASE_ARTIFACTS_LOG)" 2>&1; then \
		echo "verify: release artifact validation failed; inspect $(VERIFY_RELEASE_ARTIFACTS_LOG)"; \
		exit 1; \
	fi; \
	echo "verify stage: release artifact validation passed"; \
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
		--helm-binary "$${HELM_BINARY:-}" \
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
	@PRODUCT_VERSION="$${PRODUCT_VERSION:-$$(tr -d '[:space:]' < configs/default-product-version)}"; \
	RELEASE_WORK_ROOT="$${RELEASE_WORK_ROOT:-$${TMPDIR:-/tmp}/appliance-build}"; \
	EXPORT_DIR="$${RELEASE_WORK_ROOT}/export"; \
	if [ -z "$${PRODUCT_VERSION}" ]; then \
		echo "publish-release: missing configs/default-product-version (or set PRODUCT_VERSION)" >&2; \
		exit 2; \
	fi; \
	if [ ! -d "$${EXPORT_DIR}" ]; then \
		echo "publish-release: export directory not found: $${EXPORT_DIR} (set RELEASE_WORK_ROOT)" >&2; \
		exit 2; \
	fi; \
	export PRODUCT_VERSION RELEASE_WORK_ROOT; \
	if [ -z "$${PUBLISH_MODE:-}" ]; then \
		echo "publish-release: PUBLISH_MODE is required (from bundle_store.mode)" >&2; \
		exit 2; \
	fi; \
	if [ -z "$${PUBLISH_PATH_PREFIX:-}" ]; then \
		echo "publish-release: PUBLISH_PATH_PREFIX is required (from bundle_store.release_path_prefix)" >&2; \
		exit 2; \
	fi; \
	if [ -z "$${PUBLISH_PUBLIC_BASE_URL:-}" ]; then \
		echo "publish-release: PUBLISH_PUBLIC_BASE_URL is required (from bundle_store.base_url)" >&2; \
		exit 2; \
	fi; \
	mode="$${PUBLISH_MODE}"; \
	case "$$mode" in \
		static_http) \
			if [ -z "$${PUBLISH_SERVER:-}" ] || [ -z "$${PUBLISH_REMOTE_ROOT:-}" ]; then \
				echo "publish-release: static_http mode requires PUBLISH_SERVER and PUBLISH_REMOTE_ROOT" >&2; \
				exit 2; \
			fi; \
			bash ./scripts/publish/publish-release.sh \
				--release-work-root "$${RELEASE_WORK_ROOT}" \
				--product-version "$${PRODUCT_VERSION}" \
				--mode static_http \
				--server "$${PUBLISH_SERVER}" \
				--remote-root "$${PUBLISH_REMOTE_ROOT}" \
				--path-prefix "$${PUBLISH_PATH_PREFIX}" \
				--public-base-url "$${PUBLISH_PUBLIC_BASE_URL}" \
				$${PUBLISH_SSH_PORT:+--ssh-port "$${PUBLISH_SSH_PORT}"} \
				$${PUBLISH_LATEST_ALIAS:+--latest-alias} \
			;; \
		appliance_files) \
			bash ./scripts/publish/publish-release.sh \
				--release-work-root "$${RELEASE_WORK_ROOT}" \
				--product-version "$${PRODUCT_VERSION}" \
				--mode appliance_files \
				--path-prefix "$${PUBLISH_PATH_PREFIX}" \
				--public-base-url "$${PUBLISH_PUBLIC_BASE_URL}" \
				$${PUBLISH_LATEST_ALIAS:+--latest-alias} \
			;; \
		*) \
			echo "publish-release: PUBLISH_MODE must be static_http or appliance_files (got $$mode)" >&2; \
			exit 2; \
			;; \
	esac


.PHONY: clean
clean:
	rm -rf bin .run
	rm -rf bin .agents/.DS_Store
