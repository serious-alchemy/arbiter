#!/usr/bin/env bash
# k2-startup-window.sh <n> -- n fresh worker-labelled pods probe the API ClusterIP, the node and 1.1.1.1 from their
# first instruction for 6 s (script: pod-scripts-startup.sh, via ConfigMap). GATE=1 first waits until a must-be-blocked
# canary is rejected and logs how long that took. Any OPEN line = the pod was unfiltered while starting.
cd "$(dirname "$0")"; . ./lib.sh
k create configmap startup-script --from-file=startup.sh=pod-scripts-startup.sh -o yaml --dry-run=client | k apply -f - >/dev/null
for n in $(seq 1 "$1"); do
cat <<YAML | k apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: startup-$n, namespace: arbiter-workers, labels: {app.kubernetes.io/name: arbiter-worker, app.kubernetes.io/component: worker}}
spec:
  restartPolicy: Never
  hostUsers: false
  automountServiceAccountToken: false
  enableServiceLinks: false
  securityContext: {runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: c
    image: $IMG
    imagePullPolicy: IfNotPresent
    env: [{name: GATE, value: "${GATE:-0}"}]
    securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
    command: [bash, /s/startup.sh]
    volumeMounts: [{name: s, mountPath: /s, readOnly: true}]
  volumes: [{name: s, configMap: {name: startup-script}}]
YAML
done
for n in $(seq 1 "$1"); do
  for i in $(seq 1 60); do ph=$(k get pod startup-$n -o jsonpath='{.status.phase}'); [ "$ph" = Succeeded ] || [ "$ph" = Failed ] && break; sleep 1; done
  echo "startup-$n: $(k logs startup-$n | tr '\n' ' ' | cut -c1-260)"
  k delete pod startup-$n --wait=false >/dev/null
done
