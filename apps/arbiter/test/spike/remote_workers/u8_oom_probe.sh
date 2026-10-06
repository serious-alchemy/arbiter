#!/usr/bin/env bash
# RW2 spike (bd-6tx1xv) U8, standalone (no Elixir): is rootless `--memory` enforced here,
# and is `.State.OOMKilled` readable after exit when `--rm` is absent?
#
#   u8_oom_probe.sh [image]        (image must already be on the node and contain perl;
#                                   default docker.io/library/debian:12)
#
# The allocator runs under `systemd-run --user --scope -p MemoryMax=3G` so a broken cap
# cannot take the host down. Prints PASS/FAIL lines; exit 0 only if everything passed.
set -u
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
img=${1:-docker.io/library/debian:12}
n=rw2-u8-$$
fail=0
big='print scalar reverse("a" x 300000000)'
guard=(systemd-run --user --scope -q -p MemoryMax=3G --)
check() { if [ "$2" = "$3" ]; then echo "PASS $1 ($2)"; else echo "FAIL $1: got '$2', want '$3'"; fail=1; fi; }

echo "controllers delegated to podman: $(podman info --format '{{range .Host.CgroupControllers}}{{.}} {{end}}')"
"${guard[@]}" podman run --name "$n" --memory=64m --memory-swap=64m --cpus=1 "$img" perl -e "$big" >/dev/null 2>&1
check "exit code under cap" "$?" 137
check "OOMKilled after exit (no --rm)" "$(podman inspect "$n" --format '{{.State.OOMKilled}}' 2>&1)" true
podman rm -f "$n" >/dev/null 2>&1
"${guard[@]}" podman run --rm --name "$n-rm" --memory=64m --memory-swap=64m "$img" perl -e "$big" >/dev/null 2>&1
check "exit code under cap with --rm" "$?" 137
if podman inspect "$n-rm" >/dev/null 2>&1; then echo "FAIL --rm container still inspectable"; fail=1; else echo "PASS --rm leaves nothing to inspect (so OOMKilled needs no --rm)"; fi
out=$(podman run --rm --cpuset-cpus=0 "$img" true 2>&1); rc=$?
echo "INFO --cpuset-cpus=0 -> rc=$rc: $(echo "$out" | head -c 160)"
exit $fail
