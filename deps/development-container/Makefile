BUILD ?= podman build
OCI_TOOL ?= podman
RUN ?= podman run
TAG ?= latest
DEBIAN_VARIANT ?= bookworm
GO_VERSION ?= 1.26.0
NODE_VERSION ?= 22.19.0

BASE_IMAGE ?= localhost/automation-base:$(TAG)
GO_IMAGE ?= localhost/automation-go:$(TAG)
PYTHON_IMAGE ?= localhost/automation-python:$(TAG)
DEV_IMAGE ?= localhost/dev-build:$(TAG)

# Publishing. Set these in the environment (or make args):
#   DEV_REGISTRY, DEV_IMAGE_REPO, DEV_IMAGE_NAME, DEV_REGISTRY_USER, DEV_REGISTRY_TOKEN
# Full destination path: $(DEV_REGISTRY)/$(DEV_IMAGE_REPO)/$(DEV_IMAGE_NAME)
# DEV_REGISTRY_TLS_VERIFY=false skips registry TLS verification (LAN / appliance CA not
# yet trusted on the client). Default true for GHCR.
DEV_REGISTRY ?=
DEV_IMAGE_REPO ?= zoncaesaradmin/development-container
DEV_IMAGE_NAME ?= dev-build
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
DEV_REGISTRY_TLS_VERIFY ?= true

REMOTE_IMAGE := $(DEV_REGISTRY)/$(DEV_IMAGE_REPO)/$(DEV_IMAGE_NAME)

# podman login/push: --tls-verify=false when DEV_REGISTRY_TLS_VERIFY is false/0/no.
TLS_VERIFY_FLAG :=
ifeq ($(filter false 0 no FALSE NO,$(DEV_REGISTRY_TLS_VERIFY)),$(DEV_REGISTRY_TLS_VERIFY))
TLS_VERIFY_FLAG := --tls-verify=false
endif

.PHONY: build-base build-go build-python build-dev build-all test-dev shell-dev clean \
	login tag-dev push-dev publish release \
	build push test

# Shared deps/ package surface (aliases).
build: build-dev
push: push-dev
test: test-dev

build-base:
	$(BUILD) --build-arg DEBIAN_VARIANT=$(DEBIAN_VARIANT) -f Containerfile.base -t $(BASE_IMAGE) .

build-go: build-base
	$(BUILD) --build-arg BASE_IMAGE=$(BASE_IMAGE) --build-arg GO_VERSION=$(GO_VERSION) -f Containerfile.go -t $(GO_IMAGE) .

build-python: build-base
	$(BUILD) --build-arg BASE_IMAGE=$(BASE_IMAGE) -f Containerfile.python -t $(PYTHON_IMAGE) .

build-dev:
	$(BUILD) --build-arg DEBIAN_VARIANT=$(DEBIAN_VARIANT) --build-arg GO_VERSION=$(GO_VERSION) --build-arg NODE_VERSION=$(NODE_VERSION) -f Containerfile.dev -t $(DEV_IMAGE) .

build-all: build-base build-go build-python build-dev

test-dev:
	$(RUN) --rm $(DEV_IMAGE) bash -lc "go version && python3 --version && node --version && npm --version && git --version && gcc --version | head -n 1 && podman --version && buildah --version && skopeo --version"

shell-dev:
	$(RUN) --rm -it --privileged --device /dev/fuse -v $(CURDIR):/workspace -w /workspace $(DEV_IMAGE) bash

login:
	@test -n "$(DEV_REGISTRY)" || (echo "DEV_REGISTRY is not set" >&2 && exit 1)
	@test -n "$(DEV_REGISTRY_USER)" || (echo "DEV_REGISTRY_USER is not set" >&2 && exit 1)
	@test -n "$(DEV_REGISTRY_TOKEN)" || (echo "DEV_REGISTRY_TOKEN is not set" >&2 && exit 1)
	@command -v podman >/dev/null 2>&1 || (echo "podman is required on PATH" >&2 && exit 1)
	echo "$(DEV_REGISTRY_TOKEN)" | $(OCI_TOOL) login $(TLS_VERIFY_FLAG) --username "$(DEV_REGISTRY_USER)" --password-stdin $(DEV_REGISTRY)

tag-dev:
	$(OCI_TOOL) tag $(DEV_IMAGE) $(REMOTE_IMAGE):$(VERSION)
	$(OCI_TOOL) tag $(DEV_IMAGE) $(REMOTE_IMAGE):latest

push-dev: tag-dev
	$(OCI_TOOL) push $(TLS_VERIFY_FLAG) $(REMOTE_IMAGE):$(VERSION)
	$(OCI_TOOL) push $(TLS_VERIFY_FLAG) $(REMOTE_IMAGE):latest

publish: login
	$(MAKE) push-dev
	@echo "Published $(REMOTE_IMAGE):$(VERSION) and $(REMOTE_IMAGE):latest"

# login before publish so the push only proceeds after a successful registry login.
release:
	$(MAKE) build-dev
	$(MAKE) publish

clean:
	find . -type d \( -name __pycache__ -o -name .pytest_cache -o -name .mypy_cache -o -name .ruff_cache -o -name .cache -o -name .local \) -prune -exec rm -rf {} +
	find . -type f \( -name .coverage -o -name '*.log' -o -name '.DS_Store' \) -delete
