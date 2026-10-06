#!/usr/bin/env bash
# Boot a DISPOSABLE single-node k3s v1.36.5 (the operator cluster's version) inside a
# throwaway QEMU/KVM VM: no sudo, user-mode networking, nothing on the host is changed.
# Why a VM and not kind/k3d/k3s-in-rootless-podman: on this host the user slice delegates only
# `cpu io memory pids` (no cpuset -> k3s refuses to start; a faked controllers file breaks the
# kubelet's openat2), and br_netfilter is not loaded (same-node pod-to-pod NetworkPolicy
# would not be enforced, which would make K2 meaningless). A VM has real cgroups and a real kernel.
# Usage: 00-vm.sh <workdir with debian-13-genericcloud-amd64.qcow2> <kubeconfig-out>
# Run it as:  systemd-run --user --scope -p MemoryMax=3G 00-vm.sh ...   (VM RAM is 2560 MiB)
set -euo pipefail
W=${1:?workdir}; OUT=${2:?kubeconfig out}; SSHP=12222; APIP=16443
cd "$W"
[ -f id_spike ] || ssh-keygen -q -t ed25519 -N '' -f id_spike
if [ ! -f disk.qcow2 ]; then
  qemu-img create -q -f qcow2 -F qcow2 -b debian-13-genericcloud-amd64.qcow2 disk.qcow2 14G
fi
cat > user-data <<UD
#cloud-config
users:
  - name: spike
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: ["$(cat id_spike.pub)"]
package_update: true
packages: [socat, openssl, curl, iptables, conntrack, netcat-openbsd, git, iproute2, ca-certificates, jq]
runcmd:
  - [ bash, -c, "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='v1.36.5+k3s1' INSTALL_K3S_EXEC='server --disable traefik --disable servicelb --disable metrics-server --tls-san 127.0.0.1 --write-kubeconfig-mode 644' sh - > /var/log/k3s-install.log 2>&1" ]
  - [ touch, /var/lib/cloud/k3s-installed ]
UD
echo "instance-id: spike-1" > meta-data
genisoimage -quiet -output seed.iso -volid cidata -joliet -rock user-data meta-data
qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 2560 -display none -daemonize \
  -pidfile qemu.pid -serial file:console.log \
  -drive file=disk.qcow2,if=virtio -drive file=seed.iso,if=virtio,media=cdrom,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$SSHP-:22,hostfwd=tcp:127.0.0.1:$APIP-:6443 \
  -device virtio-net-pci,netdev=n0
SSH="ssh -i id_spike -p $SSHP -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR spike@127.0.0.1"
for i in $(seq 1 120); do $SSH true 2>/dev/null && break; sleep 3; done
for i in $(seq 1 200); do $SSH test -f /var/lib/cloud/k3s-installed 2>/dev/null && break; sleep 3; done
$SSH cat /etc/rancher/k3s/k3s.yaml | sed "s#https://127.0.0.1:6443#https://127.0.0.1:$APIP#" > "$OUT"
chmod 600 "$OUT"; echo "kubeconfig: $OUT; ssh: $SSH"
