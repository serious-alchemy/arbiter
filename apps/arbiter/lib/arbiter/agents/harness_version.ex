defmodule Arbiter.Agents.HarnessVersion do
  @moduledoc """
  The version of the agent CLI a run used (G18, `docs/design/guardrail-profiles.md`
  §6.3): a harness upgrade resets the subject's trust promotion clock, because a
  harness can change behaviour silently (agy's settings grammar did, bd-80talz).

  Two sources, the stream first:

    * **In-stream.** Claude's `init` event carries `claude_code_version`
      (`Arbiter.Worker.ClaudeSession`). It is the CLI that actually ran, wherever
      it ran — host, container or another node.
    * **The host binary** (`host/2`), for a host-local spawn whose stream says
      nothing (agy, Codex, grok): the same executable the adapter spawns is asked
      `--version`, once per build. The answer is cached against the binary's
      size, mtime and inode, so an upgrade is asked again and every other spawn
      costs one `stat`. A container or remote-node spawn is never probed here:
      the host's binary is not the one that ran.

  Probing is on by default and off in the test config
  (`config :arbiter, :harness_version, probe: false`), so the suite never runs a
  real agent CLI.
  """

  @default_timeout_ms 3_000
  @version ~r/(?<![\w.])v?(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.\-]+)?)/

  @doc """
  The version the host's CLI for `provider` reports, or `nil` (probing off, no
  binary, no answer in time, no version in the answer).

  Options: `:probe` (default from `config :arbiter, :harness_version`),
  `:executable` (skip the `PATH` lookup) and `:timeout_ms` (#{@default_timeout_ms}).
  """
  @spec host(atom() | String.t() | nil, keyword()) :: String.t() | nil
  def host(provider, opts \\ []) do
    with true <- Keyword.get_lazy(opts, :probe, &enabled?/0),
         path when is_binary(path) <-
           Keyword.get_lazy(opts, :executable, fn -> executable(provider) end),
         {:ok, identity} <- identity(path) do
      cached(path, identity, Keyword.get(opts, :timeout_ms, @default_timeout_ms))
    else
      _ -> nil
    end
  end

  @doc "The first version number in a CLI's `--version` answer, without a leading `v`."
  @spec parse(String.t()) :: String.t() | nil
  def parse(output) when is_binary(output) do
    case Regex.run(@version, output, capture: :all_but_first) do
      [version] -> version
      _ -> nil
    end
  end

  defp enabled? do
    :arbiter |> Application.get_env(:harness_version, []) |> Keyword.get(:probe, true)
  end

  # The executable each adapter spawns (`Arbiter.Agents.*`'s own lookups).
  defp executable(provider) do
    case to_string(provider || "claude") do
      "claude" -> System.find_executable("claude")
      p when p in ["gemini", "antigravity", "agy"] -> gemini_executable()
      "codex" -> System.find_executable("codex")
      "grok" -> System.find_executable("grok")
      _ -> nil
    end
  end

  defp gemini_executable do
    case Arbiter.Agents.Gemini.resolve_executable() do
      {:ok, {_cli, path}} -> path
      _ -> nil
    end
  end

  # `File.stat/2` follows a symlink, so an installer that swaps the link to a new
  # build is a new identity too.
  defp identity(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, {stat.size, stat.mtime, stat.inode}}
      _ -> :error
    end
  end

  defp cached(path, identity, timeout_ms) do
    key = {__MODULE__, path}

    case :persistent_term.get(key, nil) do
      {^identity, version} ->
        version

      _ ->
        version = probe(path, timeout_ms)
        :persistent_term.put(key, {identity, version})
        version
    end
  end

  # `path` is the adapter's own executable (`executable/1`: `System.find_executable/1`
  # or the agy resolver), never request input, and the only argument is the literal
  # `--version`. An agent CLI, so it runs through `ReleaseEnv.cmd/3`: a child that
  # inherits the release's ROOTDIR/BINDIR/RELEASE_* can fail to boot (bd-2oelme).
  defp probe(path, timeout_ms) do
    task =
      Task.async(fn ->
        Arbiter.Worker.ReleaseEnv.cmd(path, ["--version"], stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> parse(output)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
