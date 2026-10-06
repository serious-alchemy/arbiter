#!/usr/bin/env bash
# RW2 spike (bd-6tx1xv) U9/U10: the join script's host prerequisite probes, as a
# prototype. Sourced by the tests (and runnable: `prereq_checks.sh all`).
# Prototype only -- the real join script is RW4 (docs/design/remote-workers.md §5.5).
#
# Everything reads through $PC_CGROOT / $PC_UID so a test can point it at a
# fixture tree, and through `loginctl` / `podman` on $PATH so a test can shim them.

PC_CGROOT=${PC_CGROOT:-/sys/fs/cgroup}
PC_UID=${PC_UID:-$(id -u)}

# cgroup v2 unified hierarchy at $PC_CGROOT?  (design: `stat -fc %T /sys/fs/cgroup` = cgroup2fs)
pc_cgroup_v2() {
  if [ -n "${PC_FIXTURE:-}" ]; then [ -f "$PC_CGROOT/cgroup.controllers" ]; return; fi
  [ "$(stat -fc %T "$PC_CGROOT" 2>/dev/null)" = cgroup2fs ]
}

# The cgroup systemd hands the user's *manager* is where delegation is decided:
# user.slice/user-<uid>.slice/user@<uid>.service. (A login session scope under
# user-<uid>.slice is NOT delegated, so reading /proc/self/cgroup alone misleads.)
pc_user_manager_cgroup() {
  echo "$PC_CGROOT/user.slice/user-$PC_UID.slice/user@$PC_UID.service"
}

# pc_delegated <controller>: the user manager owns <controller> (listed in its
# cgroup.controllers AND enabled in its cgroup.subtree_control, which is what
# lets a child cgroup -- a container scope -- use it).
pc_delegated() {
  local c=$1 d
  d=$(pc_user_manager_cgroup)
  [ -r "$d/cgroup.controllers" ] || return 1
  tr ' ' '\n' <"$d/cgroup.controllers" | grep -qx "$c" || return 1
  # subtree_control may be absent on a leaf; delegation needs it enabled for children.
  [ -r "$d/cgroup.subtree_control" ] && tr ' ' '\n' <"$d/cgroup.subtree_control" | grep -qx "$c"
}

# Space-separated delegated controller list, for the readiness report.
pc_delegated_list() {
  local d
  d=$(pc_user_manager_cgroup)
  [ -r "$d/cgroup.controllers" ] && cat "$d/cgroup.controllers"
}

# linger: "yes" | "no" | "unknown"
pc_linger() {
  local out
  out=$(loginctl show-user "${PC_USER:-$USER}" -p Linger --value 2>/dev/null) || { echo unknown; return; }
  case $out in yes | no) echo "$out" ;; *) echo unknown ;; esac
}

# The one user-level, sudo-less repair the design allows (§5.5). Never prompts.
pc_try_enable_linger() {
  loginctl --no-ask-password enable-linger "${PC_USER:-$USER}" 2>/dev/null
}

# Functional probe: the only check that proves --memory is *enforced* here,
# independent of any file layout. Needs an image already on the node (the
# agent's own toolchain image); prints ok | unsupported | error.
pc_podman_memory_probe() {
  local image=$1 out
  out=$(podman run --rm --memory=64m --memory-swap=64m "$image" true 2>&1) && { echo ok; return; }
  case $out in
    *"controller"*"not available"* | *"memory"*"not supported"* | *"ignored"*) echo unsupported ;;
    *) echo "error: $out" ;;
  esac
}

# What podman itself believes it was delegated (cross-check for pc_delegated).
pc_podman_controllers() {
  podman info --format '{{range .Host.CgroupControllers}}{{.}} {{end}}' 2>/dev/null
}

if [ "${1:-}" = all ]; then
  echo "cgroup_v2=$(pc_cgroup_v2 && echo yes || echo no)"
  echo "delegated=[$(pc_delegated_list)]"
  for c in cpu memory pids io cpuset; do echo "delegated_$c=$(pc_delegated $c && echo yes || echo no)"; done
  echo "linger=$(pc_linger)"
  echo "podman_controllers=[$(pc_podman_controllers)]"
fi
