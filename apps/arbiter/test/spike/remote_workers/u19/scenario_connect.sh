#!/usr/bin/env bash
# RW2 spike (bd-6tx1xv) U19, the jail topology: the real Claude CLI -> HTTPS_PROXY (a CONNECT
# relay with injected faults, standing in for node listener + mux) -> a local TLS "api.anthropic.com"
# (NODE_EXTRA_CA_CERTS). Loopback-only namespace, fake key, no real credential:
#
#   unshare --user --map-root-user --net bash -c 'ip link set lo up; ./scenario_connect.sh c_stall30 stall 30'
#
# usage: scenario_connect.sh NAME MODE SECONDS [SSE_DELTA_SLEEP]   (MODE: see relay.py)
set -u
NAME=$1 MODE=$2 SECS=$3 SLEEP=${4:-0}
here=$(cd "$(dirname "$0")" && pwd)
WORK=${U19_WORK:-${TMPDIR:-/tmp}/rw2-u19}
mkdir -p $WORK
if [ ! -f $WORK/cert.pem ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -keyout $WORK/key.pem -out $WORK/cert.pem -days 2 -subj "/CN=api.anthropic.com" -addext "subjectAltName=DNS:api.anthropic.com" 2>/dev/null
fi
D=$WORK/outc-$NAME; mkdir -p $D; : > $D/api.log; : > $D/relay.log
python3 -I $here/fakeapi_tls.py 18081 $D/api.log $SLEEP $WORK/cert.pem $WORK/key.pem & API=$!
python3 -I $here/relay_connect.py 18080 18081 $MODE $SECS $D/relay.log & REL=$!
export HOME=$D/home; mkdir -p $HOME
export CLAUDE_CONFIG_DIR=$HOME/.claude
unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL
export ANTHROPIC_API_KEY=sk-ant-api03-spikefakefakefakefakefakefakefakefakefakefakefake-AAAA
export HTTPS_PROXY=http://127.0.0.1:18080 https_proxy=http://127.0.0.1:18080 NODE_EXTRA_CA_CERTS=$WORK/cert.pem
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_TELEMETRY=1 DISABLE_AUTOUPDATER=1
cd $HOME
S=$(date +%s.%N)
timeout 400 claude -p "say pong" --output-format json --max-turns 1 < /dev/null > $D/claude.out 2> $D/claude.err; RC=$?
E=$(date +%s.%N)
python3 -I - <<PY
import json
s=open("$D/claude.out").read()
try:
    j=json.loads(s); res=f"is_error={j.get('is_error')} result={str(j.get('result'))[:70]!r}"
except Exception: res="no-json: "+s[:200].replace("\n"," ")
print(f"CONNECT-PROXY $NAME mode=$MODE secs=$SECS rc=$RC elapsed={float('$E')-float('$S'):.1f}s {res}")
PY
echo "  api POSTs: $(grep -c POST $D/api.log) served ok: $(grep -c 'served ok' $D/api.log)  relay: $(grep -c CONNECT $D/relay.log) CONNECTs"
kill $API $REL 2>/dev/null
