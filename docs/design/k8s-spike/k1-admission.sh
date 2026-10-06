#!/usr/bin/env bash
# K1/K12: server-side dry-run of the K§8.2 pod and of one-field mutations of it against (a) Pod Security `restricted`
# on the namespace and (b) the ValidatingAdmissionPolicy in 20-vap.yaml. Each case prints the verdict and the first reason.
cd "$(dirname "$0")"; . ./lib.sh
export POD=adm MODE=exit0 IMG HOSTUSERS=false GITDIR_MOUNT= GRACE=30 SNAP_S=1 MEMLIM=64Mi WORKLIMIT=1Gi LOGSINK=
R() { envsubst '$POD $MODE $IMG $HOSTUSERS $GRACE $SNAP_S $MEMLIM $WORKLIMIT $GITDIR_MOUNT $LOGSINK' < k1-pod.yaml.tpl; }
t() { # <label> <expect admit|deny> <sed script or ->
  local out rc
  if [ "$3" = - ]; then out=$(R | k apply --dry-run=server -f - 2>&1); else out=$(R | sed "$3" | k apply --dry-run=server -f - 2>&1); fi
  case "$out" in *"server dry run"*) v=ADMITTED;; *) v=DENIED;; esac
  want=$([ "$2" = admit ] && echo ADMITTED || echo DENIED); ok=$([ "$v" = "$want" ] && echo ok || echo UNEXPECTED)
  printf '%-58s %-9s %-10s %s\n' "$1" "$v" "$ok" "$(echo "$out" | grep -v '^$' | head -1 | sed -E 's/.*(violates PodSecurity[^:]*: |denied request: )//' | cut -c1-120)"
}
echo "== the K§8.2 pod and one-field mutations (namespace: PSA enforce=restricted; VAP arbiter-worker-pods: Deny)"
t "as built (native sidecars, hostUsers:false, subPath)" admit -
t "PSA: appArmorProfile omitted (restricted does not need it)" admit '/appArmorProfile/d'
t "PSA: seccompProfile omitted" deny '/seccompProfile/d'
t "PSA: seccompProfile Unconfined" deny 's/seccompProfile: {type: RuntimeDefault}/seccompProfile: {type: Unconfined}/'
t "PSA: a hostPath volume" deny 's#{name: tmp, emptyDir: {medium: Memory, sizeLimit: 1Gi}}#{name: tmp, hostPath: {path: /etc}}#'
t "PSA: privileged worker (allowPrivilegeEscalation also true)" deny '/name: worker/,$ s/privileged: false/privileged: true/;/name: worker/,$ s/allowPrivilegeEscalation: false/allowPrivilegeEscalation: true/'
t "PSA: hostNetwork" deny 's/^  serviceAccountName: arbiter-worker/  hostNetwork: true\n  serviceAccountName: arbiter-worker/'
t "VAP: image not on the allowlist" deny 's#image: localhost/arbiter-dev/base:f2add20f54da#image: quay.io/evil/x:1#'
t "VAP: hostUsers true" deny 's/hostUsers: false/hostUsers: true/'
t "VAP: readOnlyRootFilesystem false on the worker" deny '/name: worker/,$ s/readOnlyRootFilesystem: true/readOnlyRootFilesystem: false/'
t "VAP: pod-level runAsUser 0 + runAsNonRoot false (PSA lets it by: hostUsers=false)" deny 's/runAsNonRoot: true/runAsNonRoot: false/;s/runAsUser: 10001/runAsUser: 0/'
t "VAP: runAsUser 0 on the worker container only" deny '/name: worker/,$ s/securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, privileged: false/securityContext: {runAsUser: 0, allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, privileged: false/'
