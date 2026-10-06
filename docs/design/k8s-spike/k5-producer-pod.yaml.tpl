apiVersion: v1
kind: Pod
metadata: {name: ${POD}, namespace: arbiter-workers, labels: {app.kubernetes.io/name: arbiter-worker, app.kubernetes.io/component: worker}}
spec:
  restartPolicy: Never
  hostUsers: false
  automountServiceAccountToken: false
  enableServiceLinks: false
  securityContext: {runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: c
    image: ${IMG}
    imagePullPolicy: IfNotPresent
    env: [{name: BURSTS, value: "${BURSTS}"}, {name: PER, value: "${PER}"}, {name: GAP, value: "${GAP}"}, {name: PAD, value: "${PAD}"}, {name: LONG, value: "${LONG}"}]
    securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
    command: [bash, /s/producer.sh]
    volumeMounts: [{name: s, mountPath: /s, readOnly: true}]
  volumes: [{name: s, configMap: {name: k5-producer}}]
