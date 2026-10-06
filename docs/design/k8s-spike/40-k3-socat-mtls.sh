#!/usr/bin/env bash
# K3: the base image's socat as the in-pod bridge client (OPENSSL: target, fork per connection) against the
# OTP :ssl mTLS listener from k4_mint.exs. Usage: 40-k3-socat-mtls.sh <certdir> <image> [port]
set -uo pipefail
C=$1; IMG=$2; P=${3:-19443}
run() { podman run --rm --network=host --userns=keep-id -v "$C":/c:ro,Z "$IMG" "$@"; }
echo "socat: $(run socat -V | sed -n 2p)"
echo "OPENSSL option support: $(run sh -c 'socat -hhh 2>&1 | grep -E "^ +(cert|key|cafile|commonname|verify|openssl-min-proto-version) " | awk "{print \$1}" | tr "\n" " "')"
t() { # <label> <expect ACCEPT|REJECT> <certfile-base|none> <commonname> [verify]
  local cert=() ; [ "$3" != none ] && cert=(",cert=/c/$3.crt,key=/c/$3.key")
  out=$(run sh -c "echo ping-$1 | socat -T3 - OPENSSL:127.0.0.1:$P,cafile=/c/ca.crt,commonname=$4,verify=${5:-1}${cert[*]:-}" 2>&1); rc=$?
  printf '%-34s rc=%d reply=%s\n' "$1" "$rc" "$(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-110)"
}
t valid-proxy-leaf ACCEPT leaf-proxy arbiter-controller
t valid-arb-leaf ACCEPT leaf-arb arbiter-controller
t no-client-cert REJECT none arbiter-controller
t expired-leaf REJECT leaf-expired arbiter-controller
t leaf-from-other-CA REJECT leaf-othercA arbiter-controller
t eku-serverauth-only-leaf INFO leaf-ekuserver arbiter-controller
t wrong-server-name REJECT leaf-proxy not-the-controller
t verify-disabled-WRONG-name INFO leaf-proxy not-the-controller 0
