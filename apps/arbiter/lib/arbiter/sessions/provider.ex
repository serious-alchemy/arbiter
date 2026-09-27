defmodule Arbiter.Sessions.Provider do
  @moduledoc """
  Provider-agnostic launch payload for a session (bd-bpt0ag; RFC §5.4 —
  "staying provider-agnostic", decision 7).

  A session is a systemd scope holding a tmux server holding **some agent's**
  PTY. Everything about the scope and the tmux server is identical whatever
  runs in the pane, so the provider-specific part is small and lives behind
  this behaviour: the command tmux runs, and the environment that command
  needs.

  Claude Code is the first implementation (`Arbiter.Sessions.Provider.ClaudeCode`),
  agy (Antigravity) the second (`Arbiter.Sessions.Provider.Agy`, bd-7xuvfl).
  Adding another is an adapter plus one atom in
  `Arbiter.Sessions.Session.providers/0` — not a schema or lifecycle change.

  ## The env rule is part of the contract

  `c:env/1` may only return **non-secret** values. They become `tmux -e`
  arguments, i.e. argv tokens, and `/proc/<pid>/cmdline` is world-readable on
  this host — RFC §10.3 makes "never a secret on a command line" a hard rule,
  and this repo has a documented incident class around exactly that. A
  provider that needs a credential gets it from its per-session config dir
  (phase 3), never from here.
  """

  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Session

  @doc """
  The command tmux runs in the pane, as a single shell-command string.

  tmux hands it to `/bin/sh -c`, so it is one argv token to `tmux new-session`.
  """
  @callback command(Session.t()) :: String.t()

  @doc "Non-secret environment the pane needs. See the module's env rule."
  @callback env(Session.t()) :: [{String.t(), String.t()}]

  @doc """
  Whether the provider runs with a per-session config dir (the row's
  `config_dir`). Claude Code does (`CLAUDE_CONFIG_DIR`); agy has no such
  override, so its row carries `nil` and provisioning neither creates nor
  seeds one.
  """
  @callback config_dir?() :: boolean()

  @adapters %{
    claude_code: Arbiter.Sessions.Provider.ClaudeCode,
    agy: Arbiter.Sessions.Provider.Agy
  }

  @fallback_shell "/bin/sh"

  @doc "The adapter module for a session's provider."
  @spec adapter(Session.t() | atom()) :: module()
  def adapter(%Session{provider: provider}), do: adapter(provider)

  def adapter(provider) when is_atom(provider) do
    Map.get(@adapters, provider) ||
      raise ArgumentError,
            "no Arbiter.Sessions.Provider adapter for #{inspect(provider)} " <>
              "(known: #{inspect(Map.keys(@adapters))})"
  end

  @doc "Delegates to the session's adapter."
  @spec command(Session.t()) :: String.t()
  def command(%Session{} = session), do: adapter(session).command(session)

  @doc "Delegates to the session's adapter."
  @spec env(Session.t()) :: [{String.t(), String.t()}]
  def env(%Session{} = session), do: adapter(session).env(session)

  @doc "Delegates to the provider's adapter. See `c:config_dir?/0`."
  @spec config_dir?(Session.t() | atom()) :: boolean()
  def config_dir?(session_or_provider), do: adapter(session_or_provider).config_dir?()

  @doc """
  The pane payload every adapter shares: the provisioned `launch.sh` when
  there is one, else an interactive shell.

  `config :arbiter, :sessions_launch_command, "…"` overrides both — see
  `Arbiter.Sessions.Provider.ClaudeCode`'s moduledoc for why an unprovisioned
  pane gets a shell rather than the agent.
  """
  @spec launch_payload(Session.t()) :: String.t()
  def launch_payload(%Session{id: id}) do
    script = Layout.launch_script_path(id)

    Application.get_env(:arbiter, :sessions_launch_command) ||
      if(File.regular?(script), do: script, else: interactive_shell())
  end

  # The operator's own shell, so an unprovisioned pane behaves like the terminal
  # it replaces.
  defp interactive_shell, do: System.get_env("SHELL") || @fallback_shell
end
