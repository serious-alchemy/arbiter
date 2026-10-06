# The K§8.2 pod, with the spike's scripts mounted from a ConfigMap instead of rendered in.
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: arbiter-workers
  labels: {app.kubernetes.io/name: arbiter-worker, app.kubernetes.io/component: worker}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: ${GRACE}
  serviceAccountName: arbiter-worker
  automountServiceAccountToken: false
  enableServiceLinks: false
  hostUsers: ${HOSTUSERS}
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    fsGroupChangePolicy: OnRootMismatch
    seccompProfile: {type: RuntimeDefault}
    appArmorProfile: {type: RuntimeDefault}
  initContainers:
  - name: seed
    image: ${IMG}
    imagePullPolicy: IfNotPresent
    command: [sh, /spike/seed.sh]
    securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, privileged: false, capabilities: {drop: [ALL]}}
    volumeMounts:
    - {name: work, mountPath: /work}
    - {name: spike, mountPath: /spike, readOnly: true}
  - name: snapshotter
    image: ${IMG}
    imagePullPolicy: IfNotPresent
    restartPolicy: Always
    command: [sh, /spike/snapshotter.sh]
    env: [{name: SNAP_S, value: "${SNAP_S}"}, {name: LOGSINK, value: "${LOGSINK}"}]
    securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, privileged: false, capabilities: {drop: [ALL]}}
    volumeMounts:
    - {name: work, mountPath: /wt/proj, subPath: wt}
${GITDIR_MOUNT}
    - {name: work, mountPath: /wt/proj/.git/config, subPath: wt/.git/config, readOnly: true}
    - {name: work, mountPath: /wt/proj/.git/hooks, subPath: wt/.git/hooks, readOnly: true}
    - {name: work, mountPath: /wt/proj/.git/commondir, subPath: wt/.git/commondir, readOnly: true}
    - {name: work, mountPath: /wt/proj/.git/objects/info/alternates, subPath: wt/.git/objects/info/alternates, readOnly: true}
    - {name: spike, mountPath: /spike, readOnly: true}
  containers:
  - name: worker
    image: ${IMG}
    imagePullPolicy: IfNotPresent
    command: [sh, /spike/worker.sh]
    env: [{name: MODE, value: "${MODE}"}, {name: LOGSINK, value: "${LOGSINK}"}, {name: HOME, value: /home/arb}]
    securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, privileged: false, capabilities: {drop: [ALL]}}
    resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {memory: ${MEMLIM}}}
    volumeMounts:
    - {name: work, mountPath: /wt/proj, subPath: wt}
${GITDIR_MOUNT}
    - {name: work, mountPath: /wt/proj/.git/config, subPath: wt/.git/config, readOnly: true}
    - {name: work, mountPath: /wt/proj/.git/hooks, subPath: wt/.git/hooks, readOnly: true}
    - {name: work, mountPath: /wt/proj/.git/commondir, subPath: wt/.git/commondir, readOnly: true}
    - {name: work, mountPath: /wt/proj/.git/objects/info/alternates, subPath: wt/.git/objects/info/alternates, readOnly: true}
    - {name: work, mountPath: /home/arb, subPath: home}
    - {name: tmp, mountPath: /tmp}
    - {name: spike, mountPath: /spike, readOnly: true}
  volumes:
  - {name: work, emptyDir: {sizeLimit: ${WORKLIMIT}}}
  - {name: tmp, emptyDir: {medium: Memory, sizeLimit: 1Gi}}
  - {name: spike, configMap: {name: spike-scripts}}
