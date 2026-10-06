# native sidecar: its SIGTERM handler is the "main container is done" signal (K§10.3).
now() { date +%s.%N; }
# LOGSINK=host:port mirrors every line to a TCP listener, for runs whose pod (and so its logs) is gone afterwards
say() { echo "$*"; [ -z "${LOGSINK:-}" ] || echo "$*" | socat -u - "TCP:$LOGSINK,connect-timeout=1" 2>/dev/null; }
say "snap: start $(now) id=$(id -u) uid_map=$(tr -s ' ' < /proc/self/uid_map | tr '\n' ';')"
say "snap: guard check: $( (echo x > /wt/proj/.git/config) 2>&1 | head -1 )"
term() {
  say "snap: GOT SIGTERM at $(now)"
  i=0
  while [ "$i" -lt "${SNAP_S:-5}" ]; do i=$((i+1)); sleep 1; say "snap: uploading tick $i at $(now)"; done
  say "snap: final snapshot done at $(now)"
  exit 0
}
trap term TERM INT
while :; do sleep 1 & wait $!; done
