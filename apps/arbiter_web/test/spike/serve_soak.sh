#!/usr/bin/env bash
# RW2 spike (bd-6tx1xv) U1: drive serve_soak_test.exs against the operator's REAL
# `tailscale serve`. It ADDS two throwaway HTTPS ports on this node's serve config
# (default 8443 = whole app, 8444 = `--set-path /node/socket` + `/nodes`), never
# touches the existing :443 mapping, and removes both on exit; it then diffs the
# serve config against what it started with and says so if they differ.
#
#   SPIKE_SOAK_SECONDS=1800 test/spike/serve_soak.sh      (run from apps/arbiter_web)
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
full=${SPIKE_FULL_PORT:-8443}
pathp=${SPIKE_PATH_PORT:-8444}
backend=${SPIKE_PORT:-47811}
work=$(mktemp -d "${TMPDIR:-/tmp}/rw2-u1.XXXXXX")

host=$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
[ -n "$host" ] || { echo "no tailscale DNS name" >&2; exit 2; }
before="$work/serve.before.json"
tailscale serve status --json >"$before"
if grep -q "\"$full\"\|\"$pathp\"" "$before"; then
  echo "refusing: port $full or $pathp already in the serve config" >&2
  exit 2
fi

cleanup() {
  tailscale serve --https="$full" off >/dev/null 2>&1
  tailscale serve --https="$pathp" off >/dev/null 2>&1
  tailscale serve status --json >"$work/serve.after.json"
  if diff -q "$before" "$work/serve.after.json" >/dev/null; then
    echo "serve config restored: identical to the starting config"
  else
    echo "WARNING: serve config differs from the start:" >&2
    diff "$before" "$work/serve.after.json" >&2
  fi
}
trap cleanup EXIT

tailscale serve --bg --https="$full" "http://127.0.0.1:$backend" >/dev/null || exit 3
tailscale serve --bg --https="$pathp" --set-path /node/socket "http://127.0.0.1:$backend/node/socket" >/dev/null || exit 3
tailscale serve --bg --https="$pathp" --set-path /nodes "http://127.0.0.1:$backend/nodes" >/dev/null || exit 3
tailscale serve status

cd "$here/../.." || exit 2
SPIKE_SERVE_HOST=$host SPIKE_PORT=$backend SPIKE_FULL_PORT=$full SPIKE_PATH_PORT=$pathp \
  MIX_ENV=test mix test --include spike_serve test/spike/serve_soak_test.exs
