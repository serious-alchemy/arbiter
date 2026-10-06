now() { date +%s.%N; }
say() { echo "$*"; [ -z "${LOGSINK:-}" ] || echo "$*" | socat -u - "TCP:$LOGSINK,connect-timeout=1" 2>/dev/null; }
cd /wt/proj
echo "worker: start $(now) mode=$MODE id=$(id -u):$(id -g) groups=$(id -G)"
echo "worker: uid_map=$(tr -s ' ' < /proc/self/uid_map | tr '\n' ';')"
echo "worker: apparmor=$(cat /proc/self/attr/current 2>&1) seccomp=$(grep Seccomp: /proc/self/status | tr -d '\t')"
echo "worker: NoNewPrivs=$(grep NoNewPrivs /proc/self/status | tr -d '\t') CapEff=$(grep CapEff /proc/self/status | tr -d '\t')"
echo "worker: ro rootfs: $( (touch /rootfs-probe) 2>&1 | head -1 )"
ls -ln /wt/proj/.git
echo "--- K8 guard probes (expected: every line says an error) ---"
p() { echo "probe $1: $( (eval "$1") 2>&1 | head -1) [rc=$?]"; }
p 'mv .git/config .git/config.x'
p 'rm -f .git/config'
p 'echo evil >> .git/config'
p 'mv .git/hooks .git/hooks.x'
p 'rm -rf .git/hooks'
p 'echo evil > .git/hooks/pre-commit'
p 'rm -f .git/commondir'
p 'echo evil > .git/commondir'
p 'echo /x >> .git/objects/info/alternates'
p 'mv .git/objects/info/alternates .git/objects/info/alt2'
p 'mv .git .git2'
echo "--- controls (expected: succeed) ---"
echo "control: write HEAD: $( (echo 'ref: refs/heads/main' > .git/HEAD) 2>&1 && echo ok)"
echo "control: write file in tree: $( (echo hi > file.txt) 2>&1 && echo ok)"
echo "control: git add/commit: $(git -c user.name=a -c user.email=a@b -c core.hooksPath=/dev/null add file.txt 2>&1 && git -c user.name=a -c user.email=a@b commit -q -m x 2>&1 && git log --oneline 2>&1 | head -1)"
echo "control: config still intact: $(cat .git/config | tr '\n' '|')"
case "${MODE:-exit0}" in
  exit0) echo "worker: exiting 0 at $(now)"; exit 0;;
  exit3) echo "worker: exiting 3 at $(now)"; exit 3;;
  oom) echo "worker: filling /tmp (memory-backed) at $(now)"; dd if=/dev/zero of=/tmp/fill bs=1M count=900 2>&1 | tail -1; echo "worker: SURVIVED $(now)";;
  evict) echo "worker: overfilling work emptyDir at $(now)"; dd if=/dev/zero of=/wt/proj/bigfile bs=1M count=400 2>&1 | tail -1; while :; do sleep 1; done;;
  sleep) say "worker: sleeping $(now)"; trap 'say "worker: got TERM $(now)"; sleep 3; say "worker: exiting after TERM $(now)"; exit 143' TERM; while :; do sleep 1 & wait $!; done;;
esac
