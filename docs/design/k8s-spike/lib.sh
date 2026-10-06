# Sourced by the spike scripts. Requires SPIKE_KUBECONFIG (a private kubeconfig for the
# DISPOSABLE VM cluster) and SPIKE_VSSH (path to a script that ssh-es into the VM).
# The operator's ~/.kube/config is never read: KUBECONFIG is forced.
: "${SPIKE_KUBECONFIG:?set SPIKE_KUBECONFIG to the disposable cluster kubeconfig}"
export KUBECONFIG="$SPIKE_KUBECONFIG"
SRV=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
[ "$SRV" = "https://127.0.0.1:16443" ] || { echo "refusing: kubeconfig does not point at the spike VM (127.0.0.1:16443)" >&2; exit 99; }
NS=${NS:-arbiter-workers}
IMG=${IMG:-localhost/arbiter-dev/base:f2add20f54da}
k() { kubectl -n "$NS" "$@"; }
vssh() { "$SPIKE_VSSH" "$@"; }
