#!/usr/bin/env bash
# RW2 spike (bd-6tx1xv) U5: does the published release boot as an agent
# (ARB_ROLE=agent) with no SECRET_KEY_BASE, no database and no cloak key?
#
# Works on a COPY of the release (never the live one) inside a private user+net
# namespace with distribution off, a scratch HOME and no DATABASE_PATH, so it
# cannot touch the live install, epmd, ports or ~/.arbiter.
#
#   u5_agent_boot.sh [release-dir]        (default: ~/.arbiter/current)
#
# Prototype only: the role gate is applied by patching the copied release's
# runtime.exs and recompiling the two Application modules from the tag's source
# with the release's own Elixir. Nothing here ships.
set -euo pipefail

if [ -z "${U5_IN_NS:-}" ]; then
  # Re-exec in a private user+net namespace (loopback only, nothing routable).
  exec env U5_IN_NS=1 unshare --user --map-root-user --net "$0" "$@"
fi
ip link set lo up 2>/dev/null || true

here=$(cd "$(dirname "$0")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
src=$(readlink -f "${1:-$HOME/.arbiter/current}")
work=$(mktemp -d "${TMPDIR:-/tmp}/rw2-u5.XXXXXX")
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$work"' EXIT
rel="$work/rel"
vsn=$(basename "$(ls -d "$src"/releases/*/ | head -1)")
echo "release: $src (version $vsn)"
command cp -a --reflink=auto "$src" "$rel"
mkdir -p "$work/home" "$work/tmp"
cd "$work" # erl_crash.dump lands in the cwd
chmod u+w "$rel/releases/COOKIE" 2>/dev/null || true

env_base=(env -i PATH="$PATH" HOME="$work/home" TMPDIR="$work/tmp" RELEASE_DISTRIBUTION=none
  RELEASE_TMP="$work/tmp" RELEASE_COOKIE=spike LANG=C.UTF-8
  # The stub agent modules are not in the .app module list, and releases boot in
  # `embedded` mode (no code loading); real agent modules are compiled in.
  RELEASE_MODE=interactive)

# boot <label> [VAR=val ...]: run `bin/arbiter start` until it reports or dies.
boot() {
  local label=$1
  shift
  local out="$work/$label.out" t0 t1 pid beam
  t0=$(date +%s%3N)
  "${env_base[@]}" "$@" "$rel/bin/arbiter" start >"$out" 2>&1 &
  pid=$!
  for _ in $(seq 1 160); do
    grep -q 'AGENT_READY\|\*\* (\|Runtime terminating\|CRASH' "$out" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  t1=$(date +%s%3N)
  echo "--- $label: observed after $((t1 - t0)) ms ---"
  if grep -q AGENT_READY "$out"; then
    grep -m1 AGENT_READY "$out" | sed 's/^/  /'
    local ready_ms
    ready_ms=$(grep -m1 AGENT_READY "$out" | sed -E 's/.*"os_time_ms":([0-9]+).*/\1/')
    echo "  start -> ready (OS clock, includes the shell wrapper and VM boot): $((ready_ms - t0)) ms"
    beam=$(pgrep -f "beam.smp.*$work" | head -1 || true)
    [ -n "$beam" ] && echo "  beam OS pid $beam VmRSS=$(awk '/VmRSS/{print $2" kB"}' /proc/"$beam"/status 2>/dev/null)"
  else
    head -c 900 "$out" | sed 's/^/  /'
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pkill -P "$pid" 2>/dev/null || true
}

echo "== 1. negative control: unpatched release, ARB_ROLE=agent, no SECRET_KEY_BASE (what an agent hits today)"
boot unpatched ARB_ROLE=agent

echo "== 2. patch the COPY: runtime.exs role gate + gated Application modules + agent stub"
python3 - "$rel/releases/$vsn/runtime.exs" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
assert s.startswith("import Config")
body = s[len("import Config"):]
gated = ("import Config\n\nif System.get_env(\"ARB_ROLE\") == \"agent\" do\n  config :arbiter, role: :agent\nelse\n"
         + "\n".join(("  " + l if l.strip() else l) for l in body.splitlines()) + "\nend\n")
open(p, "w").write(gated)
PY
git -C "$repo" show "v$vsn:apps/arbiter/lib/arbiter/application.ex" >"$work/arbiter.application.ex"
git -C "$repo" show "v$vsn:apps/arbiter_web/lib/arbiter_web/application.ex" >"$work/arbiter_web.application.ex"
python3 - "$work" <<'PY'
import sys
w = sys.argv[1]
gate = ("  def start(_type, _args) do\n"
        "    if Application.get_env(:arbiter, :role, :primary) == :agent do\n"
        "      %s\n    else\n      start_primary()\n    end\n  end\n\n  defp start_primary do\n")
for name, agent in (("arbiter", "Arbiter.NodeAgent.Supervisor.start_link([])"),
                    ("arbiter_web", "Supervisor.start_link([], strategy: :one_for_one, name: ArbiterWeb.Supervisor)")):
    p = f"{w}/{name}.application.ex"
    s = open(p).read()
    assert "  def start(_type, _args) do\n" in s
    open(p, "w").write(s.replace("  def start(_type, _args) do\n", gate % agent, 1))
PY
cat >"$work/compile.exs" <<ELIXIR
for {file, app} <- [
      {"$work/arbiter.application.ex", "arbiter-$vsn"},
      {"$work/arbiter_web.application.ex", "arbiter_web-$vsn"},
      {"$here/u5/node_agent_supervisor.ex", "arbiter-$vsn"},
      {"$here/u5/node_agent_probe.ex", "arbiter-$vsn"}
    ],
    {mod, bin} <- Code.compile_file(file) do
  File.write!(Path.join(["$rel", "lib", app, "ebin", Atom.to_string(mod) <> ".beam"]), bin)
  IO.puts("compiled " <> inspect(mod))
end
ELIXIR
"${env_base[@]}" ARB_ROLE=agent SPIKE_COMPILE="$work/compile.exs" "$rel/bin/arbiter" eval 'Code.eval_file(System.fetch_env!("SPIKE_COMPILE"))' 2>&1 | tail -25

echo "== 3. agent boot: ARB_ROLE=agent, NO SECRET_KEY_BASE / DATABASE_PATH / ARBITER_CLOAK_KEY"
boot agent ARB_ROLE=agent
echo "== 4. agent boot again (warm file cache) for a second timing"
boot agent2 ARB_ROLE=agent
echo "== 5. the same patched copy WITHOUT ARB_ROLE must still hit the primary's SECRET_KEY_BASE guard (gate is opt-in, primary unchanged)"
boot primary_gate_check
