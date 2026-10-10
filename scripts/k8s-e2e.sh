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
set -eu

tool=${1:-kind}
case "$tool" in kind | k3d) ;; *) echo "usage: $0 [kind|k3d]" >&2; exit 2 ;; esac
for bin in "$tool" kubectl mix; do
  command -v "$bin" >/dev/null 2>&1 || { echo "k8s-e2e: $bin not found on PATH" >&2; exit 2; }
done

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/arb-k8s-e2e.XXXXXX")
name="arb-e2e-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
kubeconfig="$scratch/kubeconfig"
created=0

cleanup() {
  if [ "$created" = 1 ]; then
    case "$tool" in
      kind) kind delete cluster --name "$name" --kubeconfig "$kubeconfig" || true ;;
      k3d) k3d cluster delete "$name" || true ;;
    esac
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT INT TERM

case "$tool" in
  kind)
    created=1
    kind create cluster --name "$name" --kubeconfig "$kubeconfig" --wait 120s
    ;;
  k3d)
    created=1
    k3d cluster create "$name" --kubeconfig-update-default=false --kubeconfig-switch-context=false --wait
    k3d kubeconfig get "$name" >"$kubeconfig"
    ;;
esac
chmod 600 "$kubeconfig"

ARB_K8S_E2E=1 ARB_K8S_E2E_KUBECONFIG="$kubeconfig" ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-+fnu}" \
  sh -c "cd '$root/apps/arbiter' && mix test --include k8s test/k8s"
