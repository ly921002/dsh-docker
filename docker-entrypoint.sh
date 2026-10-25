#!/usr/bin/env sh
###############################################################################
# DSH web container entrypoint.
#
# Responsibilities:
#   1. Resolve a CONCRETE bind address (DSH refuses wildcard binds).
#   2. Assemble the `dsh --profile web ...` command from the environment.
#   3. Hand off to tini (PID 1) so `docker stop` delivers a clean SIGTERM.
###############################################################################
set -eu

log() { printf '[dsh-entrypoint] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. bind address
# ---------------------------------------------------------------------------
# `hostname -i` prints the container's own addresses; take the first IPv4 one.
# Override with DSH_HOST if you know the address you want (must be a concrete
# IPv4/IPv6 literal of a local interface, never 0.0.0.0 / ::).
if [ -n "${DSH_HOST:-}" ]; then
    BIND_HOST="$DSH_HOST"
else
    BIND_HOST="$(hostname -i 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -n 1 || true)"
    if [ -z "$BIND_HOST" ]; then
        BIND_HOST="$(node -e 'const os=require("os");const out=[];for(const list of Object.values(os.networkInterfaces()))for(const n of list||[])if(n&&n.family==="IPv4"&&!n.internal)out.push(n.address);process.stdout.write(out[0]||"")' 2>/dev/null || true)"
    fi
    [ -n "$BIND_HOST" ] || BIND_HOST=127.0.0.1
fi
export DSH_HOST="$BIND_HOST"
export DSH_PORT="${DSH_PORT:-3080}"

case "$BIND_HOST" in
    0.0.0.0|::|0:0:0:0:0:0:0:0|::0)
        log "DSH_HOST=$BIND_HOST is a wildcard address; DSH refuses wildcard binds."
        log "Leave DSH_HOST empty so the entrypoint can auto-detect the container IP."
        exit 64
        ;;
esac

# ---------------------------------------------------------------------------
# 2. working directory (this is what becomes the default workspace root)
# ---------------------------------------------------------------------------
: "${DSH_WORKSPACE:=/workspace}"
cd "$DSH_WORKSPACE"

# ---------------------------------------------------------------------------
# 3. command line
# ---------------------------------------------------------------------------
# Launcher flags come first; everything else is forwarded to the web app.
set -- dsh --profile web --no-open --host "$BIND_HOST" --port "$DSH_PORT"

# Advertise the root browsers actually reach (drives the printed/opened URL,
# DSH_WEB_URL and the runtime Web GUI URL). Grants no trust by itself.
if [ -n "${DSH_PUBLIC_URL:-}" ]; then
    set -- "$@" --public-url "$DSH_PUBLIC_URL"
fi

# Extra authority the /api browser-trust fence accepts (host or host:port).
# Repeatable, so the env var is split on whitespace.
if [ -n "${DSH_TRUSTED_HOST:-}" ]; then
    for authority in $DSH_TRUSTED_HOST; do
        set -- "$@" --trusted-host "$authority"
    done
fi

# TLS: paths resolve against the process cwd, material is read once and never
# re-read, there is no HTTP fallback, and DSH has no ACME client.
if [ -n "${DSH_TLS_CERT:-}" ] || [ -n "${DSH_TLS_KEY:-}" ]; then
    if [ -z "${DSH_TLS_CERT:-}" ] || [ -z "${DSH_TLS_KEY:-}" ]; then
        log "DSH_TLS_CERT and DSH_TLS_KEY must be supplied together."
        exit 64
    fi
    set -- "$@" --tls-cert "$DSH_TLS_CERT" --tls-key "$DSH_TLS_KEY"
fi

# Escape hatch for flags not covered above, e.g.
#   DSH_EXTRA_ARGS="--print-url false"
if [ -n "${DSH_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2086
    eval "set -- \"\$@\" $DSH_EXTRA_ARGS"
fi

log "workspace : $DSH_WORKSPACE"
log "dsh home  : ${DSH_HOME:-$HOME/.dsh}"
log "agents    : ${DSH_AGENTS_HOME:-$HOME/.agents}"
log "listen    : $BIND_HOST:$DSH_PORT${DSH_PUBLIC_URL:+ (public-url $DSH_PUBLIC_URL)}"
if [ -n "${DSH_PUBLIC_URL:-}" ]; then
    log "the startup URL printed below carries this process' credentials -- treat it like a password"
fi

# ---------------------------------------------------------------------------
# 4. exec
# ---------------------------------------------------------------------------
if [ "${DSH_NO_TINI:-0}" != "1" ] && [ -x /usr/bin/tini ] && [ "$$" = "1" ]; then
    exec /usr/bin/tini -- "$@"
fi
exec "$@"
