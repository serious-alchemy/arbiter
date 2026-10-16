#!/bin/sh
# CI's `helm-chart` job (bd-2u4lpp, docs/design/remote-workers.md §20.5): lint the
# arbiter-node chart, render it for every mode and reach variant, and validate each
# render against the Kubernetes OpenAPI schemas with kubeconform. Needs `helm` and
# `kubeconform` on PATH; run it from anywhere:
#
#   scripts/helm-chart-check.sh
#
# KUBE_VERSION picks the schema set (the chart's kubeVersion floor is 1.30).
set -eu

chart="$(cd "$(dirname "$0")/.." && pwd)/charts/arbiter-node"
kube_version="${KUBE_VERSION:-1.31.0}"
ns=arbiter-workers
direct="--set primary.url=https://arbiter.example.test --set networkPolicy.controllerEgress.primaryCIDRs={100.64.0.10/32,100.64.0.11/32}"

command -v helm >/dev/null || { echo "helm-chart-check: helm not on PATH" >&2; exit 2; }
command -v kubeconform >/dev/null || { echo "helm-chart-check: kubeconform not on PATH" >&2; exit 2; }

echo "== helm lint --strict"
# shellcheck disable=SC2086 # $direct is a list of --set arguments
helm lint --strict "$chart" $direct

# name | helm arguments
check() {
  name="$1"
  shift
  echo "== $name"
  # shellcheck disable=SC2068 # the arguments are already split
  helm template mesaana "$chart" --namespace "$ns" $@ |
    kubeconform -strict -summary -kubernetes-version "$kube_version" -
}

check "mode all, reach direct" $direct
check "mode bootstrap" $direct --set mode=bootstrap
check "mode node" $direct --set mode=node
check "reach tailscale" --set primary.url=https://arbiter.example.test --set reach.mode=tailscale
check "reach proxy" --set primary.url=https://arbiter.example.test --set reach.mode=proxy \
  --set reach.proxy.url=http://proxy.example.test:3128 --set 'reach.proxy.cidrs={10.9.0.5/32}'
check "admission policy" $direct --set admissionPolicy.enabled=true \
  --set 'registries[0].prefix=registry.example.test/arbiter' --set 'registries[0].pullSecret=arbiter-registry'
check "runtime class, placement, join token" $direct --set runtimeClass.create=true \
  --set placement.runtimeClassName=gvisor --set runtimeClass.handler=runsc \
  --set 'placement.tolerations[0].key=dedicated' --set 'placement.tolerations[0].operator=Exists' \
  --set placement.nodeSelector.pool=ci --set join.token=abc123

# A chart that accepts a typo, a missing primary or a catch-all CIDR would install a node
# with a silent default. Each of these must be refused.
refuse() {
  name="$1"
  shift
  echo "== refused: $name"
  # shellcheck disable=SC2068
  if helm template mesaana "$chart" --namespace "$ns" $@ >/dev/null 2>&1; then
    echo "helm-chart-check: expected '$name' to be refused" >&2
    exit 1
  fi
}

refuse "unknown top-level key" $direct --set concurency.max=3
refuse "unknown nested key" $direct --set workers.requests.gpu=1
refuse "mode outside all|bootstrap|node" $direct --set mode=everything
refuse "no primary url" --set 'networkPolicy.controllerEgress.primaryCIDRs={1.2.3.4/32}'
refuse "direct without primaryCIDRs" --set primary.url=https://arbiter.example.test
refuse "catch-all primary CIDR" --set primary.url=https://arbiter.example.test \
  --set 'networkPolicy.controllerEgress.primaryCIDRs={0.0.0.0/0}'
refuse "proxy without cidrs" --set primary.url=https://arbiter.example.test --set reach.mode=proxy \
  --set reach.proxy.url=http://proxy.example.test:3128
refuse "admission policy without registries" $direct --set admissionPolicy.enabled=true

echo "helm-chart-check: ok"
