defmodule Arbiter.Sessions.Provider.Agy do
  @moduledoc """
  agy (Antigravity) as a session provider (bd-7xuvfl, agy parity T10) — the
  second `Arbiter.Sessions.Provider` implementation.

  ## The pane

  Same shape as `Arbiter.Sessions.Provider.ClaudeCode`: `command/1` is the
  provisioned `launch.sh` (or a shell for an unprovisioned pane), and the
  wrapper `exec`s the agent. What the wrapper `exec`s is `agent_argv/2`:

      agy --prompt-interactive '<initial prompt>'

  `--prompt-interactive` rather than a bare `agy` because it is the flag agy
  documents for "run an initial prompt interactively and continue the
  session" — the pane opens on a turn that has already pointed the agent at
  its generated `GEMINI.md`, rather than on an empty prompt box whose context
  depends on which rule files agy's interactive mode happens to discover
  (headless `agy -p` discovers none at all, `Arbiter.MCP.AgentConfig.Gemini`).

  There is no `--name` (agy has no such flag) and no `--remote-control` (the
  `Session` resource refuses it for agy: bridge verification reads Claude
  Code's JSONL).

  ## No config dir: `$HOME` instead

  agy resolves every configuration input — permission posture, user memory,
  MCP servers — from `$HOME/.gemini`, with no env override
  (`Arbiter.Agents.Gemini.ConfigDir`). So an agy session has no `config_dir`
  (`config_dir?/0` is `false`) and gets its own `HOME` instead,
  `<session>/home` (`Arbiter.Sessions.Layout.home_dir/1`), seeded by
  `Arbiter.Sessions.Provisioning`. `HOME` is a path, not a secret, so it is
  fine as a `tmux -e` token (the `Provider` env rule); the MCP bearer token
  lives in a mode-`0600` file under it.

  ## Model and effort

  Absent `:model` the CLI picks, as a bare `claude` does. `:thinking` becomes
  `--effort <level>` only for a model id **without** an effort suffix
  (`-low`/`-medium`/`-high`): the 2026-09-17 operator decision is "never
  both", the same rule `Arbiter.Agents.Gemini` applies to workers.
  """

  @behaviour Arbiter.Sessions.Provider

  alias Arbiter.Agents.Gemini.Config, as: GeminiConfig
  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Provider
  alias Arbiter.Sessions.Session

  @executable "agy"

  @impl Provider
  def command(%Session{} = session), do: Provider.launch_payload(session)

  @impl Provider
  def config_dir?, do: false

  @impl Provider
  def label, do: "agy (Antigravity)"

  @impl Provider
  def account_provider, do: :antigravity

  @impl Provider
  def executable, do: @executable

  @impl Provider
  def agent_adapter, do: Arbiter.Agents.Gemini

  @impl Provider
  def env(%Session{} = session) do
    ([{"ARB_SESSION_ID", session.id}] ++
       home(session) ++
       pair("ARB_SESSION_ROOT", session.root_dir))
    |> Enum.uniq_by(&elem(&1, 0))
  end

  @doc """
  The agent argv `launch.sh` `exec`s, **unquoted** — the caller
  (`Arbiter.Sessions.Provisioning`) shell-quotes each token.

  Options: `:model` (an agy model id) and `:thinking` (an abstract effort
  level, see the moduledoc).
  """
  @spec agent_argv(Session.t(), keyword()) :: [String.t()]
  def agent_argv(%Session{} = session, opts \\ []) do
    [@executable] ++
      model_and_effort(opts) ++
      ["--prompt-interactive", initial_prompt(session)]
  end

  @doc "Where an agy session's generated instructions live: `<cwd>/GEMINI.md`."
  @spec instructions_path(Session.t()) :: String.t()
  def instructions_path(%Session{} = session) do
    Path.join(session.cwd || Layout.workspace_dir(session.id), "GEMINI.md")
  end

  @doc """
  The first turn: point the agent at its instructions by absolute path, then
  hand the pane to the operator.
  """
  @spec initial_prompt(Session.t()) :: String.t()
  def initial_prompt(%Session{} = session) do
    "This is an Arbiter-hosted interactive session. Your operating instructions " <>
      "are in #{instructions_path(session)} — read that file now if it is not " <>
      "already in your context, and follow it. Then reply with one short line " <>
      "saying you are ready, and wait for the operator."
  end

  defp model_and_effort(opts) do
    case Keyword.get(opts, :model) do
      model when is_binary(model) and model != "" ->
        ["--model", model] ++ if(effort_suffixed?(model), do: [], else: effort(opts))

      _ ->
        effort(opts)
    end
  end

  defp effort(opts) do
    case Keyword.get(opts, :thinking) do
      level when is_binary(level) and level != "" -> GeminiConfig.thinking_argv(level, :agy)
      _ -> []
    end
  end

  defp effort_suffixed?(model), do: Regex.match?(~r/-(low|medium|high)$/, model)

  # Only once provisioning has made it: an unprovisioned pane (the phase-1
  # `provision: false` shape) runs a shell, which should keep the operator's
  # real HOME rather than land in a directory that does not exist.
  defp home(%Session{id: id}) do
    dir = Layout.home_dir(id)
    if File.dir?(dir), do: [{"HOME", dir}], else: []
  end

  defp pair(_name, value) when value in [nil, ""], do: []
  defp pair(name, value), do: [{name, value}]
end
