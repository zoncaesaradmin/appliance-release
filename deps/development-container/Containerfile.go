ARG BASE_IMAGE=localhost/automation-base:latest
FROM ${BASE_IMAGE}

ARG USERNAME=devcontainer
# Required — pass --build-arg TARGETARCH=amd64|arm64 (no default).
ARG TARGETARCH
ARG GO_VERSION=1.26.0

ENV USERNAME=${USERNAME}
ENV USER_HOME=/home/${USERNAME}
ENV GOROOT=/usr/local/go
ENV GOPATH=${USER_HOME}/go
ENV PATH=${GOROOT}/bin:${GOPATH}/bin:${PATH}

USER root

COPY scripts/install-go.sh /tmp/scripts/install-go.sh
COPY scripts/cleanup.sh /tmp/scripts/cleanup.sh

RUN test -n "${TARGETARCH}" || (echo "TARGETARCH is required (amd64|arm64)" >&2; exit 1) \
    && chmod +x /tmp/scripts/install-go.sh /tmp/scripts/cleanup.sh \
    && TARGETARCH="${TARGETARCH}" /tmp/scripts/install-go.sh \
    && /tmp/scripts/cleanup.sh \
    && rm -rf /tmp/scripts

USER ${USERNAME}
WORKDIR /workspaces

