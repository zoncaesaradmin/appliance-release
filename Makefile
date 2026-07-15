SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

DEFAULT_ZONCTL_BINARY := $(CURDIR)/../appliance-ctl/bin/zonctl
ZONCTL_BINARY ?= $(DEFAULT_ZONCTL_BINARY)
APPLIANCE_CODE_DIR ?= $(CURDIR)/../appliance-code
APPLIANCE_CTL_DIR ?= $(CURDIR)/../appliance-ctl
VERIFY_LOG_DIR := $(CURDIR)/.run/logs
VERIFY_SHELL_LOG := $(VERIFY_LOG_DIR)/verify-shell.log
VERIFY_HELP_LOG := $(VERIFY_LOG_DIR)/verify-help.log
VERIFY_JSON_LOG := $(VERIFY_LOG_DIR)/verify-json.log
VERIFY_CLIENT_CONFIG_LOG := $(VERIFY_LOG_DIR)/verify-client-config.log
VERIFY_CLIENT_CONFIG_CASE_LOG := $(VERIFY_LOG_DIR)/verify-client-config-case.log
VERIFY_RELEASE_ARTIFACTS_LOG := $(VERIFY_LOG_DIR)/verify-release-artifacts.log
VERIFY_FINAL_TARGETS_LOG := $(VERIFY_LOG_DIR)/verify-final-targets.log
VERIFY_MILESTONE_CODE_CONTROLPLANE_LOG := $(VERIFY_LOG_DIR)/verify-local-milestone-appliance-code-controlplane.log
VERIFY_MILESTONE_CODE_CHART_LOG := $(VERIFY_LOG_DIR)/verify-local-milestone-appliance-code-chart.log
VERIFY_MILESTONE_CODE_UI_LOG := $(VERIFY_LOG_DIR)/verify-local-milestone-appliance-code-ui.log
VERIFY_MILESTONE_CODE_E2E_LOG := $(VERIFY_LOG_DIR)/verify-local-milestone-appliance-code-e2e.log
VERIFY_MILESTONE_CTL_LOG := $(VERIFY_LOG_DIR)/verify-local-milestone-appliance-ctl.log
VERIFY_MILESTONE_RELEASE_LOG := $(VERIFY_LOG_DIR)/verify-local-milestone-appliance-release.log
VERIFY_MILESTONE_REPORT := $(CURDIR)/.run/appliance-release/local-milestone-report.json
VERIFY_MILESTONE_REPORT_MD := $(CURDIR)/.run/appliance-release/local-milestone-report.md
FINAL_READINESS_REPORT := $(CURDIR)/.run/appliance-release/final-readiness-report.json
FINAL_READINESS_REPORT_MD := $(CURDIR)/.run/appliance-release/final-readiness-report.md
FINAL_PROFILE_INPUT_CHECKLIST := $(CURDIR)/.run/appliance-release/final-profile-input-checklist.json
FINAL_PROFILE_INPUT_CHECKLIST_MD := $(CURDIR)/.run/appliance-release/final-profile-input-checklist.md
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
	@bash scripts/publish/install-http-release.sh --help | grep -q -- '--build-catalog'
	@bash scripts/publish/install-http-release.sh --help | grep -q -- '--source-credentials'

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
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_assert_final_readiness.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_audit_profile_matrix_reports.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_validate_release_artifacts.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_summarize_release_run.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_plan_profile_matrix.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_verify_client_access.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_write_local_milestone_report.py"
	@python3 "$(RELEASE_SKILL_SCRIPT_DIR)/test_write_final_readiness_report.py"

.PHONY: verify-final-targets
verify-final-targets:
	@mkdir -p "$(VERIFY_LOG_DIR)"
	@config_file="$(VERIFY_LOG_DIR)/final-incomplete-config.yaml"; \
	printf '%s\n' \
		'release:' \
		'  version: 0.1.0' \
		'install:' \
		'  appliance_profile: builder' \
		'client_verification:' \
		'  builder:' \
		'    workflow:' \
		'      enabled: false' \
		> "$$config_file"; \
	set +e; \
	$(MAKE) --no-print-directory plan-final-profile-matrix CONFIG="$$config_file" >"$(VERIFY_LOG_DIR)/final-plan-incomplete.out" 2>"$(VERIFY_LOG_DIR)/final-plan-incomplete.err"; \
	rc="$$?"; \
	set -e; \
	if [ "$$rc" -eq 0 ]; then \
		echo "verify-final-targets: incomplete final profile matrix config was accepted"; \
		exit 1; \
	fi; \
	grep -q 'install.build_catalog_path is required for final builder workflow evidence' "$(VERIFY_LOG_DIR)/final-plan-incomplete.out"; \
	$(MAKE) --no-print-directory final-profile-input-checklist CONFIG="$$config_file" >"$(VERIFY_LOG_DIR)/final-input-checklist.out" 2>"$(VERIFY_LOG_DIR)/final-input-checklist.err"; \
	grep -q 'final-profile-input-checklist: missing final inputs' "$(VERIFY_LOG_DIR)/final-input-checklist.out"; \
	grep -q '# Final Profile Input Checklist' "$(FINAL_PROFILE_INPUT_CHECKLIST_MD)"; \
	grep -q 'Do not run the live profile matrix from this checklist' "$(FINAL_PROFILE_INPUT_CHECKLIST_MD)"; \
	if grep -q '## Commands' "$(FINAL_PROFILE_INPUT_CHECKLIST_MD)"; then \
		echo "verify-final-targets: input checklist exposed runnable profile commands"; \
		exit 1; \
	fi; \
	grep -q '"checklistOnly": true' "$(FINAL_PROFILE_INPUT_CHECKLIST)"; \
	grep -q '"readyForFinalPlan": false' "$(FINAL_PROFILE_INPUT_CHECKLIST)"; \
	grep -q 'install.build_catalog_path is required for final builder workflow evidence' "$(FINAL_PROFILE_INPUT_CHECKLIST)"; \
	set +e; \
	$(MAKE) --no-print-directory audit-final-profile-matrix >"$(VERIFY_LOG_DIR)/final-audit-missing-dirs.out" 2>"$(VERIFY_LOG_DIR)/final-audit-missing-dirs.err"; \
	rc="$$?"; \
	set -e; \
	if [ "$$rc" -eq 0 ]; then \
		echo "verify-final-targets: audit-final-profile-matrix accepted missing run dirs"; \
		exit 1; \
	fi; \
	grep -q 'set CORE_RUN_DIR=... STORAGE_RUN_DIR=... BUILDER_RUN_DIR=...' "$(VERIFY_LOG_DIR)/final-audit-missing-dirs.err"; \
	mkdir -p "$(VERIFY_LOG_DIR)/final-audit-run/core" "$(VERIFY_LOG_DIR)/final-audit-run/storage" "$(VERIFY_LOG_DIR)/final-audit-run/builder"; \
	set +e; \
	$(MAKE) --no-print-directory audit-final-profile-matrix \
		CORE_RUN_DIR="$(VERIFY_LOG_DIR)/final-audit-run/core" \
		STORAGE_RUN_DIR="$(VERIFY_LOG_DIR)/final-audit-run/storage" \
		BUILDER_RUN_DIR="$(VERIFY_LOG_DIR)/final-audit-run/builder" \
		PLAN_JSON="$(VERIFY_LOG_DIR)/missing-final-plan.json" \
		>"$(VERIFY_LOG_DIR)/final-audit-missing-plan.out" 2>"$(VERIFY_LOG_DIR)/final-audit-missing-plan.err"; \
	rc="$$?"; \
	set -e; \
	if [ "$$rc" -eq 0 ]; then \
		echo "verify-final-targets: audit-final-profile-matrix accepted missing final plan"; \
		exit 1; \
	fi; \
	grep -q 'run make plan-final-profile-matrix first' "$(VERIFY_LOG_DIR)/final-audit-missing-plan.err"

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
	echo "verify stage: final target fail-closed checks"; \
	if ! $(MAKE) --no-print-directory verify-final-targets >"$(VERIFY_FINAL_TARGETS_LOG)" 2>&1; then \
		echo "verify: final target fail-closed checks failed; inspect $(VERIFY_FINAL_TARGETS_LOG)"; \
		exit 1; \
	fi; \
	echo "verify stage: final target fail-closed checks passed"; \
	echo "verify stage: clean"; \
	$(MAKE) --no-print-directory clean >/dev/null 2>&1; \
	echo "verify stage: clean passed"; \
	echo "verify: all local checks passed"

.PHONY: verify-local-milestone
verify-local-milestone:
	@set -e; \
	echo "verify-local-milestone stage: appliance-release"; \
	$(MAKE) --no-print-directory verify; \
	mkdir -p "$(VERIFY_LOG_DIR)"; \
	printf '%s\n' 'make verify passed' >"$(VERIFY_MILESTONE_RELEASE_LOG)"; \
	echo "verify-local-milestone stage: appliance-code controlplane"; \
	if ! (cd "$(APPLIANCE_CODE_DIR)/services/controlplane" && go test ./...) >"$(VERIFY_MILESTONE_CODE_CONTROLPLANE_LOG)" 2>&1; then \
		echo "verify-local-milestone: appliance-code controlplane failed; inspect $(VERIFY_MILESTONE_CODE_CONTROLPLANE_LOG)"; \
		exit 1; \
	fi; \
	echo "verify-local-milestone stage: appliance-code controlplane passed"; \
	echo "verify-local-milestone stage: appliance-code control-plane chart"; \
	if ! (cd "$(APPLIANCE_CODE_DIR)/deploy/charts/appliance-control-plane" && go test ./...) >"$(VERIFY_MILESTONE_CODE_CHART_LOG)" 2>&1; then \
		echo "verify-local-milestone: appliance-code control-plane chart failed; inspect $(VERIFY_MILESTONE_CODE_CHART_LOG)"; \
		exit 1; \
	fi; \
	echo "verify-local-milestone stage: appliance-code control-plane chart passed"; \
	echo "verify-local-milestone stage: appliance-code UI"; \
	if ! (cd "$(APPLIANCE_CODE_DIR)/services/ui" && go test ./...) >"$(VERIFY_MILESTONE_CODE_UI_LOG)" 2>&1; then \
		echo "verify-local-milestone: appliance-code UI failed; inspect $(VERIFY_MILESTONE_CODE_UI_LOG)"; \
		exit 1; \
	fi; \
	echo "verify-local-milestone stage: appliance-code UI passed"; \
	echo "verify-local-milestone stage: appliance-code local e2e"; \
	if ! $(MAKE) -C "$(APPLIANCE_CODE_DIR)/e2etests" --no-print-directory test-local >"$(VERIFY_MILESTONE_CODE_E2E_LOG)" 2>&1; then \
		echo "verify-local-milestone: appliance-code local e2e failed; inspect $(VERIFY_MILESTONE_CODE_E2E_LOG)"; \
		exit 1; \
	fi; \
	echo "verify-local-milestone stage: appliance-code local e2e passed"; \
	echo "verify-local-milestone stage: appliance-ctl"; \
	if ! (cd "$(APPLIANCE_CTL_DIR)" && go test ./...) >"$(VERIFY_MILESTONE_CTL_LOG)" 2>&1; then \
		echo "verify-local-milestone: appliance-ctl failed; inspect $(VERIFY_MILESTONE_CTL_LOG)"; \
		exit 1; \
	fi; \
	echo "verify-local-milestone stage: appliance-ctl passed"; \
	python3 "$(RELEASE_SKILL_SCRIPT_DIR)/write-local-milestone-report.py" \
		--output-json "$(VERIFY_MILESTONE_REPORT)" \
		--output-md "$(VERIFY_MILESTONE_REPORT_MD)" \
		--appliance-code-dir "$(APPLIANCE_CODE_DIR)" \
		--appliance-ctl-dir "$(APPLIANCE_CTL_DIR)" \
		--release-log-dir "$(VERIFY_LOG_DIR)" >/dev/null; \
	echo "verify-local-milestone: all non-live milestone checks passed"

.PHONY: plan-profile-matrix
plan-profile-matrix:
	@config_path="$${CONFIG:-$${APPLIANCE_RELEASE_CONFIG:-}}"; \
	if [ -z "$${config_path}" ]; then \
		echo "plan-profile-matrix: set CONFIG=/abs/path/to/appliance-release.config.yaml or APPLIANCE_RELEASE_CONFIG" >&2; \
		exit 2; \
	fi; \
	mkdir -p "$(CURDIR)/.run/appliance-release"; \
	python3 "$(RELEASE_SKILL_SCRIPT_DIR)/plan-profile-matrix.py" \
		--config "$${config_path}" \
		$${RELEASE_VERSION:+--release-version "$${RELEASE_VERSION}"} \
		$${REQUIRE_BUILDER_WORKFLOW:+--require-builder-workflow} \
		--output-json "$(CURDIR)/.run/appliance-release/profile-matrix-plan.json" \
		--output-md "$(CURDIR)/.run/appliance-release/profile-matrix-plan.md"

.PHONY: plan-final-profile-matrix
plan-final-profile-matrix:
	@config_path="$${CONFIG:-$${APPLIANCE_RELEASE_CONFIG:-}}"; \
	if [ -z "$${config_path}" ]; then \
		echo "plan-final-profile-matrix: set CONFIG=/abs/path/to/appliance-release.config.yaml or APPLIANCE_RELEASE_CONFIG" >&2; \
		exit 2; \
	fi; \
	mkdir -p "$(CURDIR)/.run/appliance-release"; \
	python3 "$(RELEASE_SKILL_SCRIPT_DIR)/plan-profile-matrix.py" \
		--config "$${config_path}" \
		$${RELEASE_VERSION:+--release-version "$${RELEASE_VERSION}"} \
		--require-builder-workflow \
		--output-json "$(CURDIR)/.run/appliance-release/final-profile-matrix-plan.json" \
		--output-md "$(CURDIR)/.run/appliance-release/final-profile-matrix-plan.md"

.PHONY: final-profile-input-checklist
final-profile-input-checklist:
	@config_path="$${CONFIG:-$${APPLIANCE_RELEASE_CONFIG:-}}"; \
	if [ -z "$${config_path}" ]; then \
		echo "final-profile-input-checklist: set CONFIG=/abs/path/to/appliance-release.config.yaml or APPLIANCE_RELEASE_CONFIG" >&2; \
		exit 2; \
	fi; \
	mkdir -p "$(CURDIR)/.run/appliance-release"; \
	set +e; \
	python3 "$(RELEASE_SKILL_SCRIPT_DIR)/plan-profile-matrix.py" \
		--config "$${config_path}" \
		$${RELEASE_VERSION:+--release-version "$${RELEASE_VERSION}"} \
		--require-builder-workflow \
		--document-title "Final Profile Input Checklist" \
		--checklist-only \
		--output-json "$(FINAL_PROFILE_INPUT_CHECKLIST)" \
		--output-md "$(FINAL_PROFILE_INPUT_CHECKLIST_MD)" \
		>"$(CURDIR)/.run/appliance-release/final-profile-input-checklist.stdout.json"; \
	rc="$$?"; \
	set -e; \
	if [ "$$rc" -eq 0 ]; then \
		echo "final-profile-input-checklist: final inputs look complete; see $(FINAL_PROFILE_INPUT_CHECKLIST_MD)"; \
	else \
		echo "final-profile-input-checklist: missing final inputs; see $(FINAL_PROFILE_INPUT_CHECKLIST_MD)"; \
	fi

.PHONY: audit-profile-matrix
audit-profile-matrix:
	@if [ -z "$${CORE_RUN_DIR:-}" ] || [ -z "$${STORAGE_RUN_DIR:-}" ] || [ -z "$${BUILDER_RUN_DIR:-}" ]; then \
		echo "audit-profile-matrix: set CORE_RUN_DIR=... STORAGE_RUN_DIR=... BUILDER_RUN_DIR=..." >&2; \
		exit 2; \
	fi
	@mkdir -p "$(CURDIR)/.run/appliance-release"
	python3 "$(RELEASE_SKILL_SCRIPT_DIR)/audit-profile-matrix-reports.py" \
		--core-run-dir "$${CORE_RUN_DIR}" \
		--storage-run-dir "$${STORAGE_RUN_DIR}" \
		--builder-run-dir "$${BUILDER_RUN_DIR}" \
		$${PLAN_JSON:+--plan-json "$${PLAN_JSON}"} \
		$${REQUIRE_BUILDER_WORKFLOW:+--require-builder-workflow} \
		--output-json "$${OUTPUT_JSON:-$(CURDIR)/.run/appliance-release/profile-matrix-audit.json}"

.PHONY: audit-final-profile-matrix
audit-final-profile-matrix:
	@if [ -z "$${CORE_RUN_DIR:-}" ] || [ -z "$${STORAGE_RUN_DIR:-}" ] || [ -z "$${BUILDER_RUN_DIR:-}" ]; then \
		echo "audit-final-profile-matrix: set CORE_RUN_DIR=... STORAGE_RUN_DIR=... BUILDER_RUN_DIR=..." >&2; \
		exit 2; \
	fi
	@plan_json="$${PLAN_JSON:-$(CURDIR)/.run/appliance-release/final-profile-matrix-plan.json}"; \
	if [ ! -f "$${plan_json}" ]; then \
		echo "audit-final-profile-matrix: missing final plan JSON: $${plan_json}" >&2; \
		echo "audit-final-profile-matrix: run make plan-final-profile-matrix first" >&2; \
		exit 2; \
	fi; \
	mkdir -p "$(CURDIR)/.run/appliance-release"; \
	python3 "$(RELEASE_SKILL_SCRIPT_DIR)/audit-profile-matrix-reports.py" \
		--core-run-dir "$${CORE_RUN_DIR}" \
		--storage-run-dir "$${STORAGE_RUN_DIR}" \
		--builder-run-dir "$${BUILDER_RUN_DIR}" \
		--plan-json "$${plan_json}" \
		--require-builder-workflow \
		--output-json "$${OUTPUT_JSON:-$(CURDIR)/.run/appliance-release/final-profile-matrix-audit.json}"

.PHONY: final-readiness-report
final-readiness-report:
	@mkdir -p "$(CURDIR)/.run/appliance-release"
	python3 "$(RELEASE_SKILL_SCRIPT_DIR)/write-final-readiness-report.py" \
		--local-milestone-json "$${LOCAL_MILESTONE_JSON:-$(VERIFY_MILESTONE_REPORT)}" \
		--final-input-checklist-json "$${FINAL_INPUT_CHECKLIST_JSON:-$(FINAL_PROFILE_INPUT_CHECKLIST)}" \
		--final-plan-json "$${FINAL_PLAN_JSON:-$(CURDIR)/.run/appliance-release/final-profile-matrix-plan.json}" \
		--final-audit-json "$${FINAL_AUDIT_JSON:-$(CURDIR)/.run/appliance-release/final-profile-matrix-audit.json}" \
		--output-json "$${OUTPUT_JSON:-$(FINAL_READINESS_REPORT)}" \
		--output-md "$${OUTPUT_MD:-$(FINAL_READINESS_REPORT_MD)}"

.PHONY: assert-final-readiness
assert-final-readiness:
	@$(MAKE) --no-print-directory final-readiness-report >/dev/null
	python3 "$(RELEASE_SKILL_SCRIPT_DIR)/assert-final-readiness.py" \
		--readiness-json "$${READINESS_JSON:-$(FINAL_READINESS_REPORT)}"

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
	@if [ -z "$${EXPORT_DIR:-}" ] || [ -z "$${PRODUCT_VERSION:-}" ] || [ -z "$${PUBLISH_SERVER:-}" ] || [ -z "$${PUBLISH_REMOTE_ROOT:-}" ]; then \
		echo "publish-release: required env vars are EXPORT_DIR=/abs/path/to/export PRODUCT_VERSION=... PUBLISH_SERVER=user@host PUBLISH_REMOTE_ROOT=/remote/root" >&2; \
		echo "publish-release: PRODUCT_VERSION may already be exported in your shell; it does not need to be passed inline if already set" >&2; \
		exit 2; \
	fi
	bash ./scripts/publish/publish-release.sh \
		--export-dir "$${EXPORT_DIR}" \
		--product-version "$${PRODUCT_VERSION}" \
		--server "$${PUBLISH_SERVER}" \
		--remote-root "$${PUBLISH_REMOTE_ROOT}" \
		$${PUBLISH_PATH_PREFIX:+--path-prefix "$${PUBLISH_PATH_PREFIX}"} \
		$${PUBLISH_SSH_PORT:+--ssh-port "$${PUBLISH_SSH_PORT}"} \
		$${PUBLISH_PUBLIC_BASE_URL:+--public-base-url "$${PUBLISH_PUBLIC_BASE_URL}"} \
		$${PUBLISH_LATEST_ALIAS:+--latest-alias}

.PHONY: clean
clean:
	rm -rf bin .run
	rm -rf bin .agents/.DS_Store
