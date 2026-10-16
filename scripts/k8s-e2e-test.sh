#!/bin/sh
# Self-test for scripts/k8s-e2e.sh using fake k3d/kubectl/mix binaries: checks the K3D override is
# honored, KUBECONFIG is exported to a temp file, and ~/.kube/config is never touched.
set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
t=$(mktemp -d "${TMPDIR:-/tmp}/k8s-e2e-test.XXXXXX")
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/home/.kube"
echo orig >"$t/home/.kube/config"

cat >"$t/bin/mykube" <<'EOF'
#!/bin/sh
echo "$* KC=$KUBECONFIG" >>"$FAKELOG"
[ "$1" = kubeconfig ] && echo "apiVersion: v1"
exit 0
EOF
cat >"$t/bin/mix" <<'EOF'
#!/bin/sh
echo "mix KC=$KUBECONFIG" >>"$FAKELOG"
EOF
printf '#!/bin/sh\nexit 0\n' >"$t/bin/kubectl"
chmod +x "$t/bin/"*

FAKELOG="$t/log" HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" K3D="mykube" sh "$here/k8s-e2e.sh" k3d

fail() { echo "FAIL: $1" >&2; exit 1; }
grep -q '^cluster create ' "$t/log" || fail "K3D override not used"
kc=$(sed -n 's/^cluster create .* KC=//p' "$t/log")
case "$kc" in "${TMPDIR:-/tmp}"/arb-k8s-e2e.*/kubeconfig) ;; *) fail "KUBECONFIG not a temp file: $kc" ;; esac
[ "$(grep -c "KC=$kc\$" "$t/log")" = "$(wc -l <"$t/log")" ] || fail "KUBECONFIG differs between calls"
[ "$(cat "$t/home/.kube/config")" = orig ] || fail "~/.kube/config modified"
[ "$(ls -A "$t/home/.kube")" = config ] || fail "~/.kube gained files"

# Prefix override ending in `--`: the tool name must follow the separator.
cat >"$t/bin/wrapper" <<'EOF'
#!/bin/sh
[ "$1" = "--" ] && shift
[ "$1" = k3d ] || { echo "wrapper: expected k3d, got $1" >&2; exit 1; }
shift
echo "$* KC=$KUBECONFIG" >>"$FAKELOG"
[ "$1" = kubeconfig ] && echo "apiVersion: v1"
exit 0
EOF
chmod +x "$t/bin/wrapper"
: >"$t/log"
FAKELOG="$t/log" HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" K3D="wrapper --" sh "$here/k8s-e2e.sh" k3d
grep -q '^cluster create ' "$t/log" || fail "prefix override did not append k3d"
echo "ok"
