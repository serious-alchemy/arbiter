#!/usr/bin/env bash
# run-pod.sh <name> <MODE> [key=value ...]  -- render k1-pod.yaml.tpl, apply, wait for the end, dump logs.
set -uo pipefail; cd "$(dirname "$0")"; . ./lib.sh
POD=$1 MODE=$2; shift 2
export POD MODE IMG HOSTUSERS=false GITDIR_MOUNT='    - {name: work, mountPath: /wt/proj/.git, subPath: wt/.git}' GRACE=30 SNAP_S=5 LOGSINK= MEMLIM=256Mi WORKLIMIT=2Gi
for kv in "$@"; do export "$kv"; done
k create configmap spike-scripts --from-file=pod-scripts -o yaml --dry-run=client | k apply -f - >/dev/null
envsubst '$POD $MODE $IMG $HOSTUSERS $GRACE $SNAP_S $MEMLIM $WORKLIMIT $GITDIR_MOUNT $LOGSINK' < k1-pod.yaml.tpl | k apply -f - || exit 1
