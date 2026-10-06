#!/usr/bin/env bash
# K11 harness: a DISPOSABLE tailnet (local headscale + two userspace tailscaled nodes, no real tailnet involved) and the Mint test.
#   60-k11-tailnet.sh up <workdir>      start headscale + node A (agent side, HTTP proxy on 127.0.0.1:18055) + node B (primary side)
#   60-k11-tailnet.sh test <workdir> [seconds]   mint certs, point B's `serve --tcp` at the test endpoint, run the Mint test
#   60-k11-tailnet.sh down <workdir>    stop exactly the processes `up` started (by recorded PID / container name)
# Needs: podman, tailscale + tailscaled, elixir, a compiled umbrella (mix test). Nothing is installed; no sudo.
set -euo pipefail
cmd=$1; W=$2; HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd)
HS=arb-k11-hs; HSPORT=18080; PROXY=18055
ts() { tailscale --socket="$W/ts/$1/ts.sock" "${@:2}"; }
case "$cmd" in
up)
  mkdir -p "$W"/hs/{etc,lib,run} "$W"/ts/{a,b}
  curl -sSL -m 30 https://raw.githubusercontent.com/juanfont/headscale/v0.29.4/config-example.yaml -o "$W/hs/etc/config.yaml"
  sed -i "s#^server_url: .*#server_url: http://127.0.0.1:$HSPORT#; s#^listen_addr: .*#listen_addr: 127.0.0.1:$HSPORT#; s#^metrics_listen_addr: .*#metrics_listen_addr: 127.0.0.1:19090#; s#^grpc_listen_addr: .*#grpc_listen_addr: 127.0.0.1:50444#; s#^  magic_dns: true#  magic_dns: false#" "$W/hs/etc/config.yaml"
  podman rm -f $HS >/dev/null 2>&1 || true
  podman run -d --name $HS --network=host -v "$W/hs/etc:/etc/headscale:Z" -v "$W/hs/lib:/var/lib/headscale:Z" -v "$W/hs/run:/var/run/headscale:Z" docker.io/headscale/headscale:v0.29.4-debug serve >/dev/null
  for i in $(seq 1 30); do curl -sf -m 2 http://127.0.0.1:$HSPORT/health >/dev/null && break; sleep 1; done
  podman exec $HS headscale users create spike >/dev/null
  KEY=$(podman exec $HS headscale preauthkeys create --user 1 --reusable --expiration 3h | tail -1 | tr -d '[:space:]')
  for n in a b; do
    extra=(); [ $n = a ] && extra=(--outbound-http-proxy-listen=127.0.0.1:$PROXY)
    (TS_NO_LOGS_NO_SUPPORT=true setsid nohup tailscaled --tun=userspace-networking --statedir="$W/ts/$n/state" --socket="$W/ts/$n/ts.sock" --port=0 "${extra[@]}" > "$W/ts/$n/tailscaled.log" 2>&1 < /dev/null & echo $! > "$W/ts/$n/pid")
  done
  sleep 4
  ts a up --login-server=http://127.0.0.1:$HSPORT --authkey="$KEY" --hostname=agent-a --accept-dns=false
  ts b up --login-server=http://127.0.0.1:$HSPORT --authkey="$KEY" --hostname=primary-b --accept-dns=false
  ts a status; echo "primary-side tailnet IP: $(ts b ip -4)";;
test)
  SECS=${3:-60}; TIP=$(ts b ip -4)
  mkdir -p "$W/certs"
  (cd "$W/certs" && SPIKE_SERVER_IP="$TIP,127.0.0.1" elixir "$HERE/k4_mint.exs" "$W/certs/out" >/dev/null)
  ts b serve --tcp=8443 off >/dev/null 2>&1 || true
  ts b serve --bg --tcp 8443 tcp://127.0.0.1:19443
  cd "$ROOT/apps/arbiter_web"
  SPIKE_TARGET_HOST="$TIP" SPIKE_CERTDIR="$W/certs/out" SPIKE_SOAK_SECONDS="$SECS" SPIKE_RESULTS_FILE="$W/k11-results.jsonl" \
    MIX_ENV=test ARB_TEST_MAX_CASES=2 systemd-run --user --scope -p MemoryMax=3G mix test --include spike_k8s test/spike/k11_proxy_ws_test.exs;;
down)
  for n in a b; do [ -f "$W/ts/$n/pid" ] && kill "$(cat "$W/ts/$n/pid")" 2>/dev/null || true; done
  podman rm -f $HS >/dev/null 2>&1 || true;;
*) echo "usage: $0 up|test|down <workdir> [seconds]" >&2; exit 2;;
esac
