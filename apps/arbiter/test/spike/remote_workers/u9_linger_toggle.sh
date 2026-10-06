#!/usr/bin/env bash
# RW2 spike (bd-6tx1xv) U9: can an unprivileged user turn linger off and on for
# THEMSELVES with no sudo and no password prompt (the join script's one allowed
# repair, docs/design/remote-workers.md §5.5)?
#
# MANUAL, not part of any test run: it briefly flips linger on the account that
# runs it. It restores the original state on exit (trap), and only does the
# off->on cycle when linger was already on, so the worst case is the identical
# end state. Do not run it on a machine whose only user session you are about
# to end.
set -u
user=${USER:-$(id -un)}
orig=$(loginctl show-user "$user" -p Linger --value 2>/dev/null)
echo "linger before: ${orig:-unknown}   (sessions: $(loginctl list-sessions --no-legend | wc -l))"
restore() {
  if [ "$orig" = yes ]; then loginctl --no-ask-password enable-linger "$user" >/dev/null 2>&1; fi
  echo "linger after:  $(loginctl show-user "$user" -p Linger --value 2>/dev/null)"
}
trap restore EXIT
if [ "$orig" = yes ]; then
  loginctl --no-ask-password disable-linger "$user"; echo "disable-linger rc=$? now=$(loginctl show-user "$user" -p Linger --value)"
  loginctl --no-ask-password enable-linger "$user";  echo "enable-linger  rc=$? now=$(loginctl show-user "$user" -p Linger --value)"
else
  loginctl --no-ask-password enable-linger "$user";  echo "enable-linger  rc=$? now=$(loginctl show-user "$user" -p Linger --value)"
fi
echo "interactive tty: $([ -t 0 ] && echo yes || echo no); XDG_SESSION_ID=${XDG_SESSION_ID:-unset}"
