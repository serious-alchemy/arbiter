#!/usr/bin/env bash
# k2-probe.sh <pod> <label> "<name> <host> <port> <expect>" ... -- connect from <pod> (bash /dev/tcp, 3 s timeout)
# result: CONNECTED (banner read) | REJECTED (immediate 'Connection refused': what kube-router answers for denied traffic when the
# target is known to have a listener, i.e. after a baseline run) | TIMEOUT (dropped)
cd "$(dirname "$0")"; . ./lib.sh
POD=$1; shift
rc=0
while IFS=' ' read -r name host port expect; do
  [ -z "$name" ] && continue
  out=$(k exec "$POD" -c c -- timeout 4 bash -c "exec 3<>/dev/tcp/$host/$port && { read -t2 -u3 l; echo CONNECTED \"\$l\"; }" 2>&1)
  case "$out" in
    CONNECTED*) res=CONNECTED;;
    *"Connection refused"*) res=REJECTED;;
    *) res=TIMEOUT;;
  esac
  want=$expect; verdict=ok
  case "$expect" in
    open) [ "$res" = CONNECTED ] || verdict=UNEXPECTED;;
    closed) [ "$res" = REJECTED ] || [ "$res" = TIMEOUT ] || verdict=UNEXPECTED;;
    any) verdict=info;;
  esac
  printf '%-34s %-22s %-10s expect=%-6s %s\n' "$name" "$host:$port" "$res" "$expect" "$verdict"
  [ "$verdict" = UNEXPECTED ] && rc=1
done
exit $rc
