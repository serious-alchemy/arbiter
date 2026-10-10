defmodule Arbiter.NodeAgent.StubPodman do
  @moduledoc """
  A stand-in `podman` for the node-agent tests (RW9): a shell script that
  records what it was asked to do under `<dir>/` and behaves as `<dir>/mode`
  says, so the agent's real argv, the real `Port` and the real exit path run
  without podman.

  What it records (the evidence the secrets tests read):

    * `run.argv` — one argument per line;
    * `run.env` — the environment the client was started with (`env -0`-free
      `NAME=value` lines);
    * `graph/config.json` — what real podman would persist: every `-e NAME`
      resolved to its value, and every `-e NAME=value` literal. A secret that
      travelled as `-e` would show here; the agent's design puts none there;
    * `secrets.seen` — the body of whatever file was bind-mounted at
      `/run/arbiter/secrets.env`, read while the "container" ran;
    * `calls` — every subcommand (`run`, `inspect`, `rm`, `kill`, …).

  A fake agent (bd-4ic681): when `<dir>/agent_script` exists it runs (`sh`) before the
  mode does, with the host paths of the run's worktree and config dir mounts and the
  container's working directory as `$1`, `$2`, `$3`; what it prints goes to
  `agent_script.out`.

  Modes (`write_mode/2`): `lines` (print `line-1`…`line-N`, exit 0), `oom` (exit 137,
  `OOMKilled=true`), `hang` (print one line, then wait until removed), `slow`
  (print `line-1`, wait for `<dir>/go`, print `line-2`, `line-3`, exit 0) and
  `big` (print `STUB_BYTES` bytes, exit 0). `ps` and `pod ps` answer `<dir>/ps.json` and `<dir>/pods.json` (RW12, the reaper). The script itself is
  `stub_podman.sh`, shared with `apps/arbiter_web`.
  """

  @script_path Path.join(__DIR__, "stub_podman.sh")
  @external_resource @script_path
  @script File.read!(@script_path)

  @doc "Create the stub under `dir`; returns the script path."
  @spec install(Path.t()) :: Path.t()
  def install(dir) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "podman")
    File.write!(path, @script)
    File.chmod!(path, 0o755)
    System.put_env("STUB_PODMAN_DIR", dir)
    path
  end

  @spec write_mode(Path.t(), String.t()) :: :ok
  def write_mode(dir, mode), do: File.write!(Path.join(dir, "mode"), mode)

  @doc "Everything the stub recorded, as one string (for marker scans)."
  @spec recorded(Path.t()) :: String.t()
  def recorded(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&(Path.basename(&1) == "podman"))
    |> Enum.map_join("\n", &File.read!/1)
  end
end
