ARG BASE_IMAGE=localhost/automation-base:latest
FROM ${BASE_IMAGE}

ARG USERNAME=devcontainer
ARG TARGETARCH=amd64
ARG GO_VERSION=1.26.0

ENV USERNAME=${USERNAME}
ENV USER_HOME=/home/${USERNAME}
ENV GOROOT=/usr/local/go
ENV GOPATH=${USER_HOME}/go
ENV PATH=${GOROOT}/bin:${GOPATH}/bin:${PATH}

USER root

COPY scripts/install-go.sh /tmp/scripts/install-go.sh
COPY scripts/cleanup.sh /tmp/scripts/cleanup.sh

RUN chmod +x /tmp/scripts/install-go.sh /tmp/scripts/cleanup.sh \
    && /tmp/scripts/install-go.sh \
    && /tmp/scripts/cleanup.sh \
    && rm -rf /tmp/scripts

USER ${USERNAME}
WORKDIR /workspaces

