#!/bin/sh
# The `:k8s` end-to-end suite (bd-cbgmcs, K13) on a DISPOSABLE cluster it creates itself.
#
#   scripts/k8s-e2e.sh [kind|k3d]        # default kind
#
# Creates cluster `arb-e2e-<random>` with a kubeconfig of its own under $TMPDIR (the default
# kubeconfig is never read or written), runs `mix test --include k8s test/k8s` in apps/arbiter,
# and deletes the cluster by its exact name on exit. Needs kind or k3d, kubectl, and a container
# runtime (podman or docker) that kind/k3d can use. It is not part of `mix test`, CI or the
# pre-push gate. See docs/remote-workers-k8s-runbook.md.
#
# K3D / KIND override the binary (or a command prefix) used, e.g. K3D="mise exec k3d@5.8.3 --"
# when k3d is only reachable through mise. KUBECONFIG is exported to the temp kubeconfig for
# everything the script runs, so ~/.kube/config is never touched.
set -eu

tool=${1:-kind}
case "$tool" in kind | k3d) ;; *) echo "usage: $0 [kind|k3d]" >&2; exit 2 ;; esac
# Used unquoted on purpose: the override may be a command prefix ("mise exec k3d@5 --").
case "$tool" in
  kind) tool_cmd=${KIND:-kind} ;;
  k3d) tool_cmd=${K3D:-k3d} ;;
esac
# A prefix ending in `--` (mise exec ... --) needs the tool name after it.
case "$tool_cmd" in
  *--) tool_cmd="$tool_cmd $tool" ;;
esac
for bin in ${tool_cmd%% *} kubectl mix; do
  command -v "$bin" >/dev/null 2>&1 || { echo "k8s-e2e: $bin not found on PATH" >&2; exit 2; }
done

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/arb-k8s-e2e.XXXXXX")
name="arb-e2e-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
kubeconfig="$scratch/kubeconfig"
: >"$kubeconfig"
chmod 600 "$kubeconfig"
KUBECONFIG="$kubeconfig"
export KUBECONFIG
created=0

cleanup() {
  if [ "$created" = 1 ]; then
    case "$tool" in
      kind) $tool_cmd delete cluster --name "$name" --kubeconfig "$kubeconfig" || true ;;
      k3d) $tool_cmd cluster delete "$name" || true ;;
    esac
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT INT TERM

case "$tool" in
  kind)
    created=1
    $tool_cmd create cluster --name "$name" --kubeconfig "$kubeconfig" --wait 120s
    ;;
  k3d)
    created=1
    $tool_cmd cluster create "$name" --kubeconfig-update-default=false --kubeconfig-switch-context=false --wait
    $tool_cmd kubeconfig get "$name" >"$kubeconfig"
    ;;
esac
chmod 600 "$kubeconfig"

ARB_K8S_E2E=1 ARB_K8S_E2E_KUBECONFIG="$kubeconfig" ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-+fnu}" \
  sh -c "cd '$root/apps/arbiter' && mix test --include k8s test/k8s"
