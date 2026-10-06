# K5 producer: BURSTS bursts of PER numbered lines (GAP s apart); every 25th burst also a LONG-byte single line.
n=0
pad=$(head -c "${PAD:-0}" /dev/zero | tr '\0' x)
for b in $(seq 1 "$BURSTS"); do
  awk -v n="$n" -v per="$PER" -v pad="$pad" 'BEGIN{for(i=1;i<=per;i++) printf "S%08d %s\n", n+i, pad}'
  n=$((n+PER))
  if [ $((b % 25)) -eq 0 ]; then n=$((n+1)); awk -v n="$n" -v L="$LONG" 'BEGIN{printf "S%08d ", n; for(i=0;i<L;i++) printf "y"; printf "\n"}'; fi
  sleep "$GAP"
done
echo "END $n"
