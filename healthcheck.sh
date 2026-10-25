#!/usr/bin/env sh
# Container healthcheck: the frontend-static fallback seat serves the SPA for
# any unmatched route, so a plain GET / answers 200 once the web app is up.
# It must hit the BIND address, not 127.0.0.1 -- the process never binds
# loopback unless DSH_HOST=127.0.0.1.
set -eu

PORT="${DSH_PORT:-3080}"
HOST="${DSH_HOST:-127.0.0.1}"

exec curl -fsS --max-time 5 "http://${HOST}:${PORT}/" -o /dev/null
