#!/usr/bin/env bash
# K2 driver on the disposable cluster: rebuild the fixtures, discover every IP, then
#   1. baseline with NO policies (every target must connect, so a later block means something),
#   2. apply the K§9.1 policies, probe from a worker, from the controller, and ingress paths,
#   3. a 6-pass repeat of the ingress paths.
# Output goes to stdout; results/k2-*.txt were produced by this script.
cd "$(dirname "$0")"; . ./lib.sh
kubectl delete -f 31-netpol.yaml --ignore-not-found >/dev/null
kubectl delete -f 30-k2-pods.yaml --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -f 30-k2-pods.yaml >/dev/null
k wait --for=condition=Ready pod/controller pod/prober pod/prober2 --timeout=120s >/dev/null; kubectl -n other-ns wait --for=condition=Ready pod/bystander --timeout=120s >/dev/null
sleep 3
CTRL=$(k get pod controller -o jsonpath='{.status.podIP}'); SVC=$(k get svc arbiter-controller -o jsonpath='{.spec.clusterIP}')
W2=$(k get pod prober2 -o jsonpath='{.status.podIP}'); BYS=$(kubectl -n other-ns get pod bystander -o jsonpath='{.status.podIP}')
DNSIP=$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}'); DNSPOD=$(kubectl -n kube-system get pod -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}')
API=$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}'); NODE=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' | tr ' ' '\n' | grep -E '^[0-9.]+$' | head -1)
GW=$(echo "$CTRL" | awk -F. '{print $1"."$2"."$3".1"}')
echo "fixtures: controller pod $CTRL svc $SVC | worker2 $W2 | other-ns pod $BYS | coredns pod $DNSPOD svc $DNSIP | API ClusterIP $API | node $NODE | cni gateway $GW"
cat > $TMPDIR/k2-worker-targets.txt <<T
controller-svc-bridge-9443 $SVC 9443 open
controller-svc-boot-9444 $SVC 9444 open
controller-pod-bridge-9443 $CTRL 9443 open
controller-svc-NONBRIDGE-8080 $SVC 8080 closed
controller-pod-NONBRIDGE-8080 $CTRL 8080 closed
api-clusterip-443 $API 443 closed
node-ip-apiserver-6443 $NODE 6443 closed
node-ip-ssh-22 $NODE 22 closed
node-cni-gateway-ssh-22 $GW 22 closed
node-kubelet-10250 $NODE 10250 closed
other-namespace-pod-8080 $BYS 8080 closed
other-worker-pod-7000 $W2 7000 closed
coredns-clusterip-tcp53 $DNSIP 53 closed
coredns-pod-tcp53 $DNSPOD 53 closed
internet-1.1.1.1-443 1.1.1.1 443 closed
internet-8.8.8.8-53 8.8.8.8 53 closed
T
cat > $TMPDIR/k2-controller-targets.txt <<T
api-clusterip-443 $API 443 open
node-ip-apiserver-6443 $NODE 6443 open
coredns-clusterip-tcp53 $DNSIP 53 open
coredns-pod-tcp53 $DNSPOD 53 open
internet-1.1.1.1-443 1.1.1.1 443 open
internet-8.8.8.8-53 8.8.8.8 53 closed
node-ip-ssh-22 $NODE 22 closed
node-kubelet-10250 $NODE 10250 closed
other-namespace-pod-8080 $BYS 8080 closed
worker-pod-7000 $(k get pod prober -o jsonpath='{.status.podIP}') 7000 closed
kube-dns-metrics-clusterip-9153 $DNSIP 9153 closed
T
echo; echo "### 1. BASELINE, no policies: every worker target must be reachable"
sed 's/ closed$/ open/' $TMPDIR/k2-worker-targets.txt | ./k2-probe.sh prober x
echo; echo "### 2. WORKER egress with the K§9.1 policies (expect open: 3 bridge-path targets; closed: everything else)"
kubectl apply -f 31-netpol.yaml >/dev/null; sleep 8
./k2-probe.sh prober x < $TMPDIR/k2-worker-targets.txt
echo; echo "### 3. CONTROLLER egress"
./k2-probe.sh controller x < $TMPDIR/k2-controller-targets.txt
echo; echo "### 4. INGRESS and worker-to-worker, 6 passes (REJECTED = enforced)"
for i in 1 2 3 4 5 6; do echo "[pass $i]"; ./k2-ingress.sh | sed -E 's/\(want ([A-Z]+)\)/want=\1/; s/ \(bash.*//; s/ \(command terminated.*//' | cut -c1-130; done
