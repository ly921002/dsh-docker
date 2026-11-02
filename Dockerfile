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

# `node:24-slim-bookworm` is NOT a real tag (the build failed with
# "docker.io/library/node:24-slim-bookworm: not found"); the correct one is
# `node:24-bookworm-slim`.
ARG NODE_IMAGE=node:24-bookworm-slim
# Default pin. Set to `latest` (or any dist-tag) to float on upstream npm.
# The CI workflow overrides this on every scheduled run, so the value here is
# only the fallback for local builds.
ARG DSH_VERSION=0.2.1-rc.5

FROM ${NODE_IMAGE}

ARG DSH_VERSION
ARG INSTALL_PWSH=0
ARG INSTALL_PYTHON=1

# Records the requested ref. The concrete resolved version goes into
# /usr/local/share/dsh/version.txt below; the published image additionally gets
# an io.dsh.dsh-version label stamped by the publish workflow (metadata-action),
# which is what the scheduled rebuild compares against npm.
LABEL org.opencontainers.image.title="dsh-web" \
      org.opencontainers.image.description="DeepSeek Harness web profile, built from the @deepseek-ai/dsh npm package" \
      org.opencontainers.image.source="https://github.com/ly921002/dsh-docker" \
      org.opencontainers.image.version="${DSH_VERSION}"

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
#
# DSH_VERSION may be a concrete version (0.2.1-rc.5) or a dist-tag (latest,
# next, alpha). Either way the version actually installed is frozen into
# /usr/local/share/dsh/version.txt so the running container can report exactly
# what it is -- a dist-tag build would otherwise be unreproducible after the
# fact.
#
# Two details that are easy to get wrong here:
#   * An empty build arg (compose passes DSH_VERSION="" to mean "use the
#     default") must not become `npm install @deepseek-ai/dsh@`, which npm
#     rejects -- hence the normalisation to `latest`.
#   * The version is read with sed off the installed package.json rather than
#     `node -e`. A node one-liner here needs both single and double quotes
#     inside a single-quoted shell argument, which is fragile; sed has no such
#     problem.
RUN set -eu; \
    VER="${DSH_VERSION}"; \
    if [ -z "$VER" ]; then VER=latest; fi; \
    echo "installing @deepseek-ai/dsh@$VER"; \
    npm install -g "@deepseek-ai/dsh@${VER}" "pnpm@10"; \
    mkdir -p /usr/local/share/dsh; \
    ROOT="$(npm root -g)"; \
    RESOLVED="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$ROOT/@deepseek-ai/dsh/package.json" | head -n1)"; \
    if [ -z "$RESOLVED" ]; then RESOLVED=unknown; fi; \
    printf '%s\n' "$RESOLVED" > /usr/local/share/dsh/version.txt; \
    echo "resolved @deepseek-ai/dsh $RESOLVED"; \
    npm cache clean --force

# The resolved version, readable at runtime (see docker-entrypoint.sh). The
# image label cannot interpolate a runtime value, so the file is the source of
# truth inside the container.
ENV DSH_INSTALLED_VERSION_FILE=/usr/local/share/dsh/version.txt

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
