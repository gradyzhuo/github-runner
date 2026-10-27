# syntax=docker/dockerfile:1
FROM ubuntu:22.04

# Pin a runner version with --build-arg RUNNER_VERSION=2.x.y; empty means "latest release".
ARG RUNNER_VERSION=""
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    RUNNER_HOME=/home/runner \
    RUNNER_ALLOW_RUNASROOT=0

# Base tools commonly needed by workflows, plus gosu for privilege drop.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg lsb-release \
        git jq unzip zip tar xz-utils iproute2 \
        sudo gosu openssh-client rsync \
        build-essential python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Docker CLI + buildx + compose (daemon comes from the host via /var/run/docker.sock).
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Non-root user that runs the runner; passwordless sudo for workflows that need it.
RUN useradd -m -d "$RUNNER_HOME" -s /bin/bash runner \
    && echo "runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/runner \
    && chmod 0440 /etc/sudoers.d/runner

WORKDIR $RUNNER_HOME

# Download the official actions/runner release for this architecture.
RUN set -eux; \
    if [ -z "$RUNNER_VERSION" ]; then \
        RUNNER_VERSION="$(curl -fsSLo /dev/null -w '%{url_effective}' https://github.com/actions/runner/releases/latest | sed 's#.*/v##')"; \
    fi; \
    case "${TARGETARCH:-$(dpkg --print-architecture)}" in \
        amd64) ARCH=x64 ;; \
        arm64) ARCH=arm64 ;; \
        *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o runner.tar.gz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz"; \
    tar xzf runner.tar.gz; \
    rm runner.tar.gz; \
    apt-get update; \
    ./bin/installdependencies.sh; \
    rm -rf /var/lib/apt/lists/*; \
    chown -R runner:runner "$RUNNER_HOME"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
