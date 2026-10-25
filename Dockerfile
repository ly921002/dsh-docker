# syntax=docker/dockerfile:1
###############################################################################
# Self-built DeepSeek Harness (DSH) web container.
#
# There is no official DSH Docker image. Upstream publishes the runtime on npm
# (`@deepseek-ai/dsh`) and the prebuilt browser bundle inside
# `@deepseek-ai/dsh-web-frontend`, so an image is just Node + that npm package.
#
# Verified facts this image is built on:
#   * The shipped runtime tree is pure JS -- no *.node native addons at all,
#     so nothing has to be rebuilt per platform.
#   * `dsh --profile web` defaults to loopback and REJECTS wildcard binds:
#       error: --host <x> is an unspecified (wildcard) address, which is not
#       supported: binding every interface would expose remote code execution
#       to the network; bind one concrete IPv4 or IPv6 address instead
#     -> the entrypoint resolves the container's own eth0 address.
#   * `--public-url` / `--trusted-host` / `--tls-cert` / `--tls-key` are the
#     only remote-access flags; the Host fence otherwise 403s every API call
#     from an authority that is not the bind address itself.
#   * On Linux the shipped `standard` preset disables the PowerShell tool row
#     and enables bash, so `pwsh` is optional (build arg, default off).
#   * Office->PDF on Linux uses the LibreOfficeKit WASM engine (no native
#     linux engine package is published), so fonts are installed here.
###############################################################################

ARG NODE_IMAGE=node:24-slim-bookworm
ARG DSH_VERSION=0.2.1-rc.3

FROM ${NODE_IMAGE}

ARG DSH_VERSION
ARG INSTALL_PWSH=0
ARG INSTALL_PYTHON=1

ENV DEBIAN_FRONTEND=noninteractive \
    DSH_HOME=/data/.dsh \
    DSH_AGENTS_HOME=/data/.agents \
    DSH_PORT=3080 \
    DSH_WORKSPACE=/workspace \
    NPM_CONFIG_UPDATE_NOTIFIER=false

# curl  -> healthcheck
# git   -> pnpm can install git-sourced plugins
# tini  -> reap zombies / forward SIGTERM as PID 1
# fonts -> LibreOfficeKit WASM PDF rendering (no font auto-discovery on Linux)
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        tini \
        fonts-dejavu-core \
        fonts-liberation; \
    if [ "$INSTALL_PYTHON" = "1" ]; then \
        apt-get install -y --no-install-recommends python3; \
    fi; \
    if [ "$INSTALL_PWSH" = "1" ]; then \
        curl -fsSL https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -o /tmp/pms.deb; \
        dpkg -i /tmp/pms.deb; \
        apt-get update; \
        apt-get install -y --no-install-recommends powershell; \
        rm -f /tmp/pms.deb; \
    fi; \
    rm -rf /var/lib/apt/lists/*

# pnpm is installed too: `dsh plugin --profile web <pnpm args>` forwards to
# pnpm inside the profile directory, and out-of-tree plugins are installed
# into $DSH_HOME/profiles/web/node_modules.
RUN npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" "pnpm@10" \
 && npm cache clean --force

COPY --chown=node:node docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY --chown=node:node healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh /usr/local/bin/healthcheck.sh

# /data     -> DSH_HOME + DSH_AGENTS_HOME (sessions, credentials, settings)
# /workspace -> the default workspace root; the directory the process runs in
#               becomes the default workspace root, so mount your code here.
RUN mkdir -p /data /workspace && chown -R node:node /data /workspace

USER node
WORKDIR /workspace

EXPOSE 3080

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
