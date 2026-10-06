#!/usr/bin/env bash
# RW2 spike (bd-6tx1xv) U13, standalone: does a container env secret reach persistent disk
# on this node? Compares `-e NAME` (the original design) with a tmpfs file mount (the fallback).
#
#   u13_secret_scan.sh [image]     (image already on the node; default docker.io/library/debian:12)
#
# Prints the files under podman's state that contain a random marker, for each method.
set -u
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
img=${1:-docker.io/library/debian:12}
marker=ARBSPIKE_$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')
roots=("$HOME/.local/share/containers" "$XDG_RUNTIME_DIR/containers" "$XDG_RUNTIME_DIR/libpod" "$HOME/.config/containers")
scan() { for d in "${roots[@]}"; do [ -e "$d" ] && grep -rlaFs "$marker" "$d" 2>/dev/null; done; }
echo "graph root: $(podman info --format '{{.Store.GraphRoot}}')  run root: $(podman info --format '{{.Store.RunRoot}}')"

a=rw2-u13a-$$
SPIKE_TOKEN=$marker podman run -d --name "$a" -e SPIKE_TOKEN "$img" sleep 30 >/dev/null
echo "== -e NAME, while running:"; scan | sed 's/^/  HIT /'
podman rm -f -t0 "$a" >/dev/null
echo "== -e NAME, after podman rm:"; scan | sed 's/^/  HIT /'

d=$XDG_RUNTIME_DIR/rw2-u13-$$; mkdir -m 0700 "$d"; ( umask 077; printf 'export SPIKE_TOKEN=%s\n' "$marker" >"$d/secrets.env" )
b=rw2-u13b-$$
podman run -d --name "$b" -v "$d/secrets.env:/run/arbiter/secrets.env:ro,Z" "$img" sh -c '. /run/arbiter/secrets.env; exec sleep 30' >/dev/null
sleep 1
echo "== tmpfs file mount, while running (process has it: $(podman exec "$b" cat /proc/1/environ | tr '\0' '\n' | grep -c '^SPIKE_TOKEN=')):"; scan | sed 's/^/  HIT /'
podman rm -f -t0 "$b" >/dev/null; python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$d" 2>/dev/null || rm -r "$d"
echo "== tmpfs file mount, after rm:"; scan | sed 's/^/  HIT /'
echo "(no HIT lines under a heading means that method left no copy where podman writes)"
