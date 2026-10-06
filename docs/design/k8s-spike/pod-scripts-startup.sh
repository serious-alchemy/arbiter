T0=$(date +%s.%N); open=0; tried=0
if [ "$GATE" = 1 ]; then
  # the proposed seed-script step 0: do nothing until a must-be-blocked canary (the kubernetes ClusterIP) is rejected
  while timeout 0.3 bash -c "exec 3<>/dev/tcp/10.43.0.1/443" 2>/dev/null; do :; done
  echo "gate: canary rejected at +$(echo "$(date +%s.%N) - $T0" | bc)s"; T0=$(date +%s.%N)
fi
end=$((SECONDS+6))
while [ $SECONDS -lt $end ]; do
  for t in 10.43.0.1:443 10.0.2.15:6443 1.1.1.1:443; do
    tried=$((tried+1))
    if timeout 0.3 bash -c "exec 3<>/dev/tcp/${t%:*}/${t#*:}" 2>/dev/null; then open=$((open+1)); echo "OPEN $t at +$(echo "$(date +%s.%N) - $T0" | bc)s"; fi
  done
done
echo "done: tried=$tried open=$open"
