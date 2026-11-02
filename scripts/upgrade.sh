#!/usr/bin/env sh
###############################################################################
# One-command upgrade of the DSH container to whatever CI last published.
#
#   ./scripts/upgrade.sh              # pull + recreate
#   ./scripts/upgrade.sh --check      # report versions, change nothing
#
# Why a script instead of `docker compose pull && docker compose up -d`:
#
#   1. compose has BOTH `image:` and `build:` on the service. On a fresh host
#      `up -d` alone would find no local image and take the build path, which
#      is slow and not what "upgrade" should mean. Pulling first pins the
#      decision to the registry.
#   2. The before/after version readout is the part that actually tells you the
#      upgrade happened -- a pull that changes nothing is otherwise invisible.
#
# Exit codes: 0 success, 1 failure, 2 usage.
###############################################################################
set -eu

CHECK_ONLY=0
case "${1:-}" in
    '') ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

VER_FILE=/usr/local/share/dsh/version.txt
CONTAINER="${DSH_CONTAINER:-dsh-web}"

log() { printf '[upgrade] %s\n' "$*" >&2; }

# Reads the version baked into the running container. Empty when it is not up,
# which is not an error -- the first install has nothing to report.
running_version() {
    docker exec "$CONTAINER" cat "$VER_FILE" 2>/dev/null || true
}

if [ "$CHECK_ONLY" = "1" ]; then
    log "running  : $(running_version || echo '<not running>')"
    log "image    : $(docker inspect --format '{{.Config.Image}}' "$CONTAINER" 2>/dev/null || echo '<none>')"
    log "label    : $(docker inspect --format '{{ index .Config.Labels "io.dsh.dsh-version" }}' "$CONTAINER" 2>/dev/null || echo '<none>')"
    exit 0
fi

BEFORE="$(running_version)"
log "before : ${BEFORE:-<not running>}"

log "pulling ${DSH_IMAGE:-ghcr.io/ly921002/dsh-docker:latest}"
docker compose pull

log "recreating"
docker compose up -d

# The entrypoint prints the resolved version; give it a moment to appear, but
# do not fail the upgrade if it is slow to boot.
i=0
AFTER=""
while [ "$i" -lt 30 ]; do
    AFTER="$(running_version)"
    [ -n "$AFTER" ] && break
    i=$((i + 1))
    sleep 1
done

log "after  : ${AFTER:-<not readable yet>}"
if [ -n "$BEFORE" ] && [ "$BEFORE" = "$AFTER" ]; then
    log "already current -- $AFTER"
else
    log "upgraded ${BEFORE:-<none>} -> ${AFTER:-<unknown>}"
fi
