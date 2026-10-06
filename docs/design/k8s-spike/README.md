# K1 spike (bd-6zl538): k8s in-cluster agent go/no-go

Evidence for the K1 verdicts in `docs/design/remote-workers.md` §16 (K§15 table and §15.1). **Spike code, not product code**:
nothing here is built or shipped; it exists so the verdicts can be rerun and checked.

* `00-vm.sh` boots a disposable single-node **k3s v1.36.5** in a throwaway QEMU/KVM VM (rootless, no sudo, user-mode networking).
  Why a VM and not kind/k3d: see §15.1 ("The cluster, and why it is a VM").
* `lib.sh` is sourced by every cluster script. It forces `KUBECONFIG=$SPIKE_KUBECONFIG` and **exits unless the API server is
  `https://127.0.0.1:16443`**, so these scripts cannot touch any other cluster by accident. `$SPIKE_VSSH` is a script that runs a command in the VM over ssh.
* `results/` holds the raw outputs the document quotes (scratch paths replaced by `$TMPDIR`).
* `k2-operator-check.sh` and `k1-operator-userns-check.sh` are **for the operator** to run on their own cluster (the spike did not):
  each refuses to run until you confirm the API server URL, uses throwaway namespaces and cleans up. Both were validated on the disposable cluster
  (`results/k2-operator-script-validated-on-disposable.txt`, `results/k1-operator-userns-check-validated-on-disposable.txt`).

| Row | Files |
|---|---|
| K1, K6, K8 | `k1-pod.yaml.tpl`, `run-pod.sh`, `wait-pod.sh`, `pod-scripts/`, `20-vap.yaml`, `21-vap-design-verbatim.yaml`, `k1-admission.sh` |
| K2 | `30-k2-pods.yaml`, `31-netpol.yaml`, `k2-run.sh`, `k2-probe.sh`, `k2-ingress.sh`, `k2-stability.sh`, `k2-startup-window.sh` + `pod-scripts-startup.sh` |
| K3, K4 | `k4_mint.exs` (mints, and with `serve` runs the OTP mTLS listener), `40-k3-socat-mtls.sh`, `41-k3-socat-fork-load.sh` |
| K5 | `k5-producer-pod.yaml.tpl` + `pod-scripts-k5-producer.sh`, `k5_logs.py`, `k5_since_probe.py` |
| K10 | `50-k10-services-pod.yaml` |
| K11 | `60-k11-tailnet.sh`; the test is `apps/arbiter_web/test/spike/k11_proxy_ws_test.exs` |
