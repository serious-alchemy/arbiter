#!/bin/sh
# The `tests` step of the "arbiter" pre-push recipe (bd-8wdrql,
# Arbiter.Worker.PrepushCheck.Recipe): run the given test files, each under its
# own umbrella app. Usage, from the repo root:
#
#   scripts/pre-push-tests.sh apps/arbiter/test/arbiter/foo_test.exs apps/arbiter_web/test/...
#
# `mix test <path>` from the umbrella root ignores the path and runs everything,
# so the files are grouped by `apps/<app>/` and run as `cd apps/<app> && mix test
# <paths relative to the app>`. No arguments (nothing mapped from the diff) is a
# green no-op. Exits non-zero if any app's run failed, after running them all.
set -u

[ "$#" -gt 0 ] || { echo "pre-push-tests: no test files to run"; exit 0; }

# The VM runs with UTF-8 file names, as in CI (LANG=C.UTF-8). Started under a
# POSIX locale (a sandbox or service with no LANG) it falls back to latin1, where
# File and Path mangle any non-ASCII name: a test with one in its fixture fails
# here and passes in CI. `+fnu` is the runtime's own suggested fix; a `+fn` flag
# already in ELIXIR_ERL_OPTIONS comes after it, so that one still wins.
ELIXIR_ERL_OPTIONS="+fnu${ELIXIR_ERL_OPTIONS:+ $ELIXIR_ERL_OPTIONS}"
export ELIXIR_ERL_OPTIONS

status=0
for app in $(printf '%s\n' "$@" | sed -n 's|^apps/\([^/]*\)/.*|\1|p' | sort -u); do
  files=$(printf '%s\n' "$@" | sed -n "s|^apps/$app/||p")
  # shellcheck disable=SC2086 # the paths are repo-relative, with no spaces
  (cd "apps/$app" && mix test $files) || status=1
done
exit $status
