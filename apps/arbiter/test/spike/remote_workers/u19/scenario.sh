#!/usr/bin/env bash
# RW2 spike (bd-6tx1xv) U19: does the real Claude CLI ride through a stalled /
# refused / reset / cut proxy socket? Run ONE scenario inside a private net
# namespace (loopback only -- the CLI cannot reach the internet, and no real
# credential is used: the "API" is fakeapi.py):
#
#   unshare --user --map-root-user --net bash -c 'ip link set lo up; ./scenario.sh refuse30 refuse 30'
#
# usage: scenario.sh NAME MODE SECONDS [SSE_DELTA_SLEEP]
#   MODE: refuse | reset | stall | stall_then_drop | cut   (see relay.py)
set -u
NAME=$1 MODE=$2 SECS=$3 SLEEP=${4:-0}
here=$(cd "$(dirname "$0")" && pwd)
WORK=${U19_WORK:-${TMPDIR:-/tmp}/rw2-u19}
D=$WORK/out-$NAME; mkdir -p $D; : > $D/api.log; : > $D/relay.log
python3 -I $here/fakeapi.py 18081 $D/api.log $SLEEP & API=$!
python3 -I $here/relay.py 18080 18081 $MODE $SECS $D/relay.log & REL=$!
export HOME=$D/home; mkdir -p $HOME
export CLAUDE_CONFIG_DIR=$HOME/.claude
unset CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_AUTH_TOKEN
export ANTHROPIC_API_KEY=sk-ant-api03-spikefakefakefakefakefakefakefakefakefakefakefake-AAAA
export ANTHROPIC_BASE_URL=http://127.0.0.1:18080
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_TELEMETRY=1 DISABLE_AUTOUPDATER=1
cd $HOME
S=$(date +%s.%N)
timeout 400 claude -p "say pong" --output-format json --max-turns 1 < /dev/null > $D/claude.out 2> $D/claude.err; RC=$?
E=$(date +%s.%N)
python3 -I - <<PY > $D/result.txt
import json
s=open("$D/claude.out").read()
try:
    j=json.loads(s); res=f"ok subtype={j.get('subtype')} is_error={j.get('is_error')} result={str(j.get('result'))[:60]!r}"
except Exception: res="no-json: "+s[:200].replace("\n"," ")
print(f"$NAME mode=$MODE secs=$SECS rc=$RC elapsed={float('$E')-float('$S'):.1f}s {res}")
PY
cat $D/result.txt
echo "  api served: $(grep -c 'served ok' $D/api.log) ok, POSTs: $(grep -c POST $D/api.log)"
kill $API $REL 2>/dev/null
