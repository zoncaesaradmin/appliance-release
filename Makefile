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

# Full product sequence for CI: bootstrap → build → publish.
# Inject DEV_*, RELEASE_WORK_ROOT, PRODUCT_VERSION (optional), etc. in the
# runner environment. Aborts on the first failing step (.SHELLFLAGS).
.PHONY: build-and-publish
build-and-publish:
	bash ./scripts/bootstrap-build-host.sh
	bash ./scripts/build-full-bundle.sh
	bash ./scripts/publish-release.sh

# Offline build-host dependency seeds (deps/*). Online machine → LAN Artifact Server.
DEPS := $(sort $(notdir $(wildcard deps/*)))

.PHONY: list-deps seed-build-deps seed-build-deps-build seed-build-deps-push seed-build-deps-login
list-deps:
	@for d in $(DEPS); do echo "$$d"; done

seed-build-deps-login:
	@bash -c 'source ./scripts/deps-common.sh && deps_oci_login'

seed-build-deps-build:
	@for d in $(DEPS); do \
		echo "==> build deps/$$d"; \
		$(MAKE) -C deps/$$d build; \
	done

seed-build-deps-push:
	@for d in $(DEPS); do \
		echo "==> push deps/$$d"; \
		$(MAKE) -C deps/$$d push; \
	done

# Build every deps package then publish to DEV_REGISTRY (OCI + files API).
seed-build-deps: seed-build-deps-build
	$(MAKE) seed-build-deps-login
	$(MAKE) seed-build-deps-push

.PHONY: verify-shell
verify-shell:
	@bash -n $$(find scripts -type f -name '*.sh' | LC_ALL=C sort)
	@bash -n $$(find deps -type f -name '*.sh' | LC_ALL=C sort)
	@bash -n $$(find "$(RELEASE_SKILL_SCRIPT_DIR)" -type f -name '*.sh' | LC_ALL=C sort)
	@bash -n configs/product-bundle.sample.env
	@bash -n configs/product-bundle.ci.env
	@PYTHONPYCACHEPREFIX="$(CURDIR)/.run/pycache" python3 -m py_compile $$(find scripts "$(RELEASE_SKILL_SCRIPT_DIR)" -type f -name '*.py' | LC_ALL=C sort)

.PHONY: verify-help
verify-help:
	@for script in $$(find scripts -type f -name '*.sh' | LC_ALL=C sort); do \
		bash "$$script" --help >/dev/null; \
	done
	@for script in $$(find "$(RELEASE_SKILL_SCRIPT_DIR)" -type f -name '*.sh' | LC_ALL=C sort); do \
		bash "$$script" --help >/dev/null; \
	done
	@bash scripts/install-http-release.sh --help | grep -q -- '--appliance-name'
	@bash scripts/install-http-release.sh --help | grep -q -- 'appliance-name'
	@bash scripts/publish-release.sh --help | grep -q -- 'DEV_REGISTRY'
	@bash scripts/publish-release.sh --help | grep -q -- 'appliance file API'

.PHONY: verify-json
verify-json:
	@python3 -c 'import json; from pathlib import Path; [json.load(path.open("r", encoding="utf-8")) for path in sorted(Path("docs").rglob("*.json"))]'

.PHONY: verify-client-config
verify-client-config:
	@mkdir -p "$(VERIFY_LOG_DIR)"
	@config_file="$(VERIFY_LOG_DIR)/client-removed-workflow.yaml"; \
	run_dir="$(VERIFY_LOG_DIR)/client-removed-workflow-run"; \
	printf '%s\n' \
		'install:' \
		'  appliance_profile: core' \
		'client_verification:' \
		'  builder:' \
		'    enabled: true' \
		'    workflow:' \
		'      enabled: true' \
		> "$$config_file"; \
	set +e; \
	APPLIANCE_FIRST_ADMIN_PASSWORD=test bash "$(RELEASE_SKILL_SCRIPT_DIR)/verify-client-access.sh" --config "$$config_file" --run-dir "$$run_dir" --appliance-profile builder >"$(VERIFY_CLIENT_CONFIG_CASE_LOG)" 2>&1; \
	status="$$?"; \
	set -e; \
	if [ "$$status" -eq 0 ]; then \
		echo "verify-client-config: removed builder.workflow block was accepted"; \
		exit 1; \
	fi; \
	grep -q 'client_verification.builder.workflow was removed' "$(VERIFY_CLIENT_CONFIG_CASE_LOG)"

.PHONY: verify-release-artifacts
verify-release-artifacts:
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_validate_release_artifacts.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_summarize_release_run.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_verify_client_access.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_live_release_repo_preflight.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_build_and_publish_config.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_bundle_store_mode.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_appliance_files_bundle_store.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_shell_quote_env.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_install_public_helper_config.py"

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

.PHONY: init-bundle-workspace
init-bundle-workspace:
	@if [ -z "$${WORKDIR:-}" ]; then \
		echo "init-bundle-workspace: set WORKDIR=/abs/path/to/workspace" >&2; \
		exit 2; \
	fi
	bash ./scripts/init-bundle-workspace.sh \
		--workdir "$${WORKDIR}" \
		--zonctl-binary "$${ZONCTL_BINARY:-$(ZONCTL_BINARY)}" \
		--helm-binary "$${HELM_BINARY:-}" \
		$${PRODUCT_VERSION:+--product-version "$${PRODUCT_VERSION}"} \
		$${CONTROL_PLANE_IMAGE_REF:+--control-plane-image-ref "$${CONTROL_PLANE_IMAGE_REF}"} \
		$${OS_VERSION:+--os-version "$${OS_VERSION}"}

# Deprecated alias.
.PHONY: init-simple-workspace
init-simple-workspace: init-bundle-workspace

.PHONY: product-bundle
product-bundle:
	@if [ -z "$${CONFIG:-}" ]; then \
		echo "product-bundle: set CONFIG=/abs/path/to/product-bundle.env" >&2; \
		exit 2; \
	fi
	bash ./scripts/assemble-product-bundle.sh --config "$${CONFIG}"

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

.PHONY: clean seed-build-deps-clean
seed-build-deps-clean:
	@for d in $(DEPS); do \
		echo "==> clean deps/$$d"; \
		$(MAKE) -C deps/$$d clean || true; \
	done
	@rm -rf deps/*/.staging

clean: seed-build-deps-clean
	rm -rf bin .run
	rm -rf bin .agents/.DS_Store
