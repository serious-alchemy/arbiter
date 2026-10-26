# SI1: the CLIs a container spawn mounts and a publish layers come from the
# pinned upstream cache (`Arbiter.Worker.CliSet`), never from a CLI installed on
# the host. The suite gets a fixture cache by default; a test about an empty or
# different cache passes its own `:cli_cache_root` (a call's options win).
cli_fixture_root =
  Path.join(System.tmp_dir!(), "arbiter-cli-set-#{System.unique_integer([:positive])}")

Application.put_env(:arbiter, :cli_set_opts, Arbiter.Worker.CliSetFixture.put(cli_fixture_root))
System.at_exit(fn _ -> File.rm_rf(cli_fixture_root) end)

System.delete_env("ARBITER_WORKTREE_ROOT")
System.delete_env("ARBITER_OUTPUT_LOG_ROOT")
System.delete_env("ARBITER_MEMORY_ROOT")

# bd-3ymdvi: `:node` tests drive the real terminal channel over a real
# WebSocket using `scripts/verify_session_transport.mjs` — the same client the
# coordinator runs for acceptance criterion 8 on the live host. No npm is
# involved (Node 22+ ships `WebSocket`, and `phoenix.mjs` is a Mix dependency),
# so they run by default and are skipped only where node is absent.
node_exclude = if System.find_executable("node"), do: [], else: [:node]

# bd-510881: `:tmux` tests (the login flows) drive a real tmux server on a
# scratch socket. Remote-node and gate containers ship no tmux, so there they
# are skipped rather than crashing with `:enoent`. Same rule as apps/arbiter.
tmux_exclude = if System.find_executable("tmux"), do: [], else: [:tmux]

# bd-c76fu9: `:browser` tests bundle the real terminal hook with esbuild and
# run it inside a headless Chromium over the DevTools Protocol, because the
# canvas renderer and the §6.3 key bindings cannot be checked anywhere else.
# Still no npm — the browser and the esbuild binary are ones already on disk —
# but a machine without either has nothing to run, so the tag is excluded
# rather than failing.
chrome_candidates = [
  System.get_env("ARB_CHROME"),
  Path.expand("~/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome"),
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
  "/usr/bin/google-chrome"
]

browser_exclude =
  if node_exclude == [] and Enum.any?(chrome_candidates, &(&1 && File.exists?(&1))),
    do: [],
    else: [:browser]

# bd-d2o3xb: `:podman` tests start REAL rootless containers (and build a
# throwaway image); opt in with `mix test --include podman <file>`.
# bd-90vo7y: ARB_TEST_MAX_CASES / worker-default cap on async cases.
max_cases_opts =
  "../../../scripts/test_max_cases.exs"
  |> Path.expand(__DIR__)
  |> Code.eval_file()
  |> elem(0)
  |> then(& &1.(System.get_env()))

# bd-6tx1xv (RW2 spike): the remote-workers go/no-go prototypes move real bytes
# over real sockets (and, for some, `tc netem` / `tailscale serve`); opt in with
# `mix test --include spike_rw <file>`. See docs/design/remote-workers.md §17.
#
# bd-afcoop (RW13): `:node_agent` boots a second BEAM as a real node agent (`ARB_ROLE=agent`)
# and drives the host's real rootless podman against a Bandit-served endpoint; opt in with
# `mix test --include node_agent test/node_agent/`. See docs/remote-workers-runbook.md.
ExUnit.start(
  [
    exclude:
      [:podman, :spike_rw, :spike_serve, :spike_k8s, :node_agent] ++
        node_exclude ++ browser_exclude ++ tmux_exclude
  ] ++
    max_cases_opts
)

Ecto.Adapters.SQL.Sandbox.mode(Arbiter.Repo, :manual)

# bd-5scl0c: report loudly, with attribution, if anything is killed while
# holding the single shared sandbox connection — it silently corrupts whatever
# test happens to be running.
Arbiter.Test.SandboxMonitor.install()
