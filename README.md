# Self-built DeepSeek Harness (DSH) web container

A Dockerfile + compose stack that runs the DeepSeek Harness web profile on
Linux. Upstream publishes no Docker image — this one is built from the npm
package `@deepseek-ai/dsh`, which ships the prebuilt browser bundle inside
`@deepseek-ai/dsh-web-frontend`, so there is no source build step.

## Contents

| File | Purpose |
| --- | --- |
| [Dockerfile](Dockerfile) | `node:24-slim-bookworm` + pinned `@deepseek-ai/dsh`, plus tini, fonts and optional pwsh/python3 |
| [docker-entrypoint.sh](docker-entrypoint.sh) | Resolves a concrete bind address and assembles the `dsh --profile web` command line |
| [healthcheck.sh](healthcheck.sh) | Probes the bind address (never loopback) once the SPA is up |
| [docker-compose.yml](docker-compose.yml) | Publishes the port on 127.0.0.1 only, persists DSH state in `./data` |
| [nginx-dsh.conf](nginx-dsh.conf) | Reverse proxy + TLS termination example with WebSocket upgrade |
| [.env.example](.env.example) | Tunable parameters |
| [DEPLOY.md](DEPLOY.md) | Full deployment walkthrough, written for an Oracle Cloud VPS |

## Quick start

```bash
cp .env.example .env
docker compose config          # syntax check first
docker compose up -d --build
docker compose logs -f dsh     # the startup URL is printed once
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

## Version

Pinned to `0.2.1-rc.3`, a developer preview with expected breaking changes.
npm's `latest` dist-tag is still `0.2.1-rc.2`; `next` tracks rc.3. Change
`DSH_VERSION` in the Dockerfile (and the build arg in
[docker-compose.yml](docker-compose.yml)) together.

## Status

These files were authored on a machine without a Docker CLI, so the image has
not been built or smoke-tested here. Run `docker compose config` before
`up -d --build`.
