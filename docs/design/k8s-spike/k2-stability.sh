#!/usr/bin/env bash
# k2-stability.sh <seconds> -- delete nothing; apply the policies at t=10 s and log every state change of four 1 Hz probes:
#   ingress: other-ns pod -> controller :9443 (must end BLOCKED)   egress: worker -> 1.1.1.1:443 (must end BLOCKED)
#   control: worker -> controller :9443 (must stay CONNECTED)       egress: controller -> API ClusterIP (must stay CONNECTED)
cd "$(dirname "$0")"; . ./lib.sh
SECS=${1:-360}; T0=$(date +%s)
probe() { # <ns> <pod> <container or -> <host> <port>
  local c=(); [ "$3" = - ] || c=(-c "$3")
  if timeout 4 kubectl -n "$1" exec "$2" "${c[@]}" -- timeout 2 bash -c "exec 3<>/dev/tcp/$4/$5" >/dev/null 2>&1; then echo CONNECTED; else echo BLOCKED; fi; }
declare -A last
( sleep 10; kubectl apply -f 31-netpol.yaml >/dev/null; echo "$(( $(date +%s) - T0 )) APPLIED" ) &
while [ $(( $(date +%s) - T0 )) -lt "$SECS" ]; do
  CTRL=$(k get pod controller -o jsonpath='{.status.podIP}'); SVC=$(k get svc arbiter-controller -o jsonpath='{.spec.clusterIP}')
  for spec in "ingress other-ns bystander - $CTRL 9443" "egress-internet arbiter-workers prober c 1.1.1.1 443" "worker-to-controller arbiter-workers prober c $SVC 9443" "controller-to-api arbiter-workers controller c 10.43.0.1 443"; do
    read -r name ns pod c host port <<<"$spec"; r=$(probe "$ns" "$pod" "$c" "$host" "$port")
    [ "${last[$name]:-}" = "$r" ] || { echo "$(( $(date +%s) - T0 ))s $name $r"; last[$name]=$r; }
  done
  sleep 1
done
echo "end ${SECS}s final: $(for n in "${!last[@]}"; do echo -n "$n=${last[$n]} "; done)"
