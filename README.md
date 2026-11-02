# Self-built DeepSeek Harness (DSH) web container

A Dockerfile + compose stack that runs the DeepSeek Harness web profile on
Linux. Upstream publishes no Docker image — this one is built from the npm
package `@deepseek-ai/dsh`, which ships the prebuilt browser bundle inside
`@deepseek-ai/dsh-web-frontend`, so there is no source build step.

## Contents

| File | Purpose |
| --- | --- |
| [Dockerfile](Dockerfile) | `node:24-bookworm-slim` + pinned `@deepseek-ai/dsh`, plus tini, fonts and optional pwsh/python3 |
| [docker-entrypoint.sh](docker-entrypoint.sh) | Resolves a concrete bind address and assembles the `dsh --profile web` command line |
| [healthcheck.sh](healthcheck.sh) | Probes the bind address (never loopback) once the SPA is up |
| [docker-compose.yml](docker-compose.yml) | Publishes the port on 127.0.0.1 only, persists DSH state in `./data` |
| [nginx-dsh.conf](nginx-dsh.conf) | Reverse proxy + TLS termination example with WebSocket upgrade |
| [.env.example](.env.example) | Tunable parameters |
| [scripts/upgrade.sh](scripts/upgrade.sh) | Pull + recreate, and print the before/after version |
| [scripts/image-label.mjs](scripts/image-label.mjs) | Read one label off a published image without pulling it |
| [DEPLOY.md](DEPLOY.md) | Full deployment walkthrough, written for an Oracle Cloud VPS |

## Quick start

```bash
cp .env.example .env
docker compose config          # syntax check first
docker compose up -d           # pulls the CI image; add --build to build locally
docker compose logs -f dsh     # the startup URL is printed once
./scripts/upgrade.sh --check   # confirm which version is actually running
```

The printed startup URL carries this process' credentials — treat it like a
password. Set `DSH_EXTRA_ARGS="--print-url false"` to keep it out of the logs.

## Why it is shaped this way

Three facts about DSH drive the design, all verified against the shipped
runtime and upstream docs:

1. **Wildcard binds are rejected.** `--host 0.0.0.0` or `::` fails at startup
   with *"binding every interface would expose remote code execution to the
   network"*. The entrypoint therefore resolves the container's own address
   from `hostname -i` and refuses to pass a wildcard through. This is also why
   the stack does not use `--network host`.

2. **Remote access needs two flags together.** `--public-url` only changes the
   printed/opened/runtime URL; it grants no trust. The `/api` Host fence is
   what actually authorises a browser, and that is `--trusted-host`. Setting
   only one of them makes every API call answer 403. Both are empty by
   default, which means "loopback + reverse proxy only".

3. **Port 3080 is bound to 127.0.0.1 by default.** Nothing is reachable until
   you put a proxy in front, and `DSH_PUBLIC_URL`/`DSH_TRUSTED_HOST` are set.

Other verified defaults: the runtime tree is pure JS (no `*.node` files), so
nothing needs a per-platform native rebuild; on Linux the `standard` preset
disables the PowerShell tool row and bash is the shell (install `pwsh` only if
a custom preset re-enables it); Office→PDF uses the LibreOfficeKit WASM engine
because no native Linux engine package is published, hence the font packages
and the 2 GB memory ceiling; full-text session search is off by default
(`openAt: never`, `:memory:`); and no telemetry runs outside the desktop
profile.

## Version and staying current

The npm package is what moves, so "keep DSH current" reduces to three
independent decisions. Pick the level you want.

| Level | What you do | Updates when |
| --- | --- | --- |
| **1. Pull on demand** | `./scripts/upgrade.sh` | you run it |
| **2. Automatic** | `docker compose --profile auto-update up -d` | watchtower sees a new `latest` digest (default: hourly) |
| **3. Local build** | `docker compose build --pull && docker compose up -d` | you rebuild |

All three sit on top of one mechanism: the CI workflow
([.github/workflows/docker-publish.yml](.github/workflows/docker-publish.yml))
runs daily at 03:17 UTC, resolves the current `@deepseek-ai/dsh` on npm
(`NPM_DIST_TAG: 'latest'`), compares it with the `io.dsh.dsh-version` label of
the image already on GHCR, and **only rebuilds when they differ**. Upstream
releases therefore reach you with no manual version editing — the old
"Dockerfile pins a version you must bump by hand" problem is gone.

Manual rebuild with an explicit version still works:

```bash
gh workflow run docker-publish.yml -f dsh_version=0.2.1-rc.5
# or locally (DSH_VERSION is read by the compose build args):
DSH_VERSION=0.2.1-rc.5 docker compose build
```

**What is actually current right now** (checked against the npm registry):

| dist-tag | version |
| --- | --- |
| `latest` | `0.2.1-rc.5` |
| `next` | `0.2.1-rc.5` |
| `alpha` | `0.2.2-alpha.2` |

The Dockerfile default is `0.2.1-rc.5`; it is only the fallback for a local
build that passes no build arg, so it does not matter that it drifts.

To confirm what a running container is on:

```bash
docker exec dsh-web cat /usr/local/share/dsh/version.txt
docker inspect --format '{{ index .Config.Labels "io.dsh.dsh-version" }}' dsh-web
./scripts/upgrade.sh --check          # both of the above, in one line each
```

Session data lives in `./data`, so every upgrade path here keeps sessions,
credentials and plugins intact. Back it up before a jump:
`cp -a data data.bak-$(date +%F)`.

### Caveat: an upgrade restarts the container

Any image swap recreates the container, which ends running agent sessions.
Level 2 can therefore interrupt work at an arbitrary moment — keep it off if
long sessions matter, and upgrade by hand instead.

## Status

The image builds and publishes from GitHub Actions
([workflow](.github/workflows/docker-publish.yml)); `latest`,
`main` and short-sha tags are on GHCR and were verified to resolve for both
`linux/amd64` and `linux/arm64`. The compose stack itself has not been run on a
host with a Docker CLI here, so run `docker compose config` before the first
`up -d`.
