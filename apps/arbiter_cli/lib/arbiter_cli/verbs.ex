defmodule ArbiterCli.Verbs do
  @moduledoc """
  The declarative registry of every first-token `arb` verb.

  One data structure that `ArbiterCli.Main` (dispatch + legacy redirects),
  `ArbiterCli.AliasResolver` (the known-verb set and typo suggestions) and the
  tests all read, so adding a command is one entry here rather than a
  `dispatch_known/2` clause plus a `@known_verbs` word plus a `@legacy` pair.

  Each entry is a map:

    * `:name` — the token the user types (`"ticket"`, `"list"`, `"upgrade"`)
    * `:kind` — `:resource` (canonical resource or meta command), `:shortcut`
      (top-level alias that prepends a subcommand, e.g. `arb dispatch`),
      `:legacy` (pre-`<resource> <verb>` flat command, redirected with a note),
      or `:orphan` (a handler module no verb reaches any more)
    * `:handler` — the `ArbiterCli.Cmd.*` module whose `run/1` is invoked
    * `:prefix` — argv prepended before `run/1` (`["dispatch"]` for shortcuts)
    * `:redirect_to` — for `:legacy` entries, the canonical resource the
      handler is reached through (the printed hint is `<resource> <prefix>`)
    * `:deprecated` — true for legacy flat verbs and the `issue` alias
    * `:host_local?` — true when the verb never talks to the server over HTTP
    * `:flags` — `{switch, type}` pairs the verb itself declares at this level
  """

  @type entry :: %{
          name: String.t(),
          kind: :resource | :shortcut | :legacy | :orphan,
          handler: module(),
          prefix: [String.t()],
          redirect_to: String.t() | nil,
          deprecated: boolean(),
          host_local?: boolean(),
          flags: [{String.t(), :boolean | :string}]
        }

  # Flags stripped centrally in `Main` before any subcommand parses argv.
  @global_flags [
    {"--json", :boolean},
    {"--workspace", :string},
    {"-w", :string},
    {"--help", :boolean}
  ]

  @cmd ArbiterCli.Cmd

  @resources [
    {"ticket", Module.concat(@cmd, Issue), []},
    {"issue", Module.concat(@cmd, Issue), [deprecated: true]},
    {"epic", Module.concat(@cmd, Epic), []},
    {"worker", Module.concat(@cmd, Worker), []},
    {"repo", Module.concat(@cmd, Repo), []},
    {"dep", Module.concat(@cmd, Dep), []},
    {"config", Module.concat(@cmd, Config), []},
    {"server", Module.concat(@cmd, Server), []},
    {"workspace", Module.concat(@cmd, Workspace), []},
    {"message", Module.concat(@cmd, Message), []},
    {"usage", Module.concat(@cmd, Usage), []},
    {"loop", Module.concat(@cmd, Loop), []},
    {"queue", Module.concat(@cmd, Queue), []},
    {"scheduler", Module.concat(@cmd, Scheduler), []},
    {"settings", Module.concat(@cmd, Settings), []},
    {"quota", Module.concat(@cmd, Quota), []},
    {"provider", Module.concat(@cmd, Provider), []},
    {"breaker", Module.concat(@cmd, Breaker), []},
    {"image", Module.concat(@cmd, Image), []},
    {"install", Module.concat(@cmd, Install), [host_local?: true]},
    {"mcp", Module.concat(@cmd, Mcp), []},
    {"skill", Module.concat(@cmd, Skill), []},
    {"session", Module.concat(@cmd, Session), [host_local?: true]},
    {"account", Module.concat(@cmd, Account), []},
    {"node", Module.concat(@cmd, Node), []},
    {"dashboard", Module.concat(@cmd, Dashboard), []},
    {"prime", Module.concat(@cmd, Prime), []},
    {"where", Module.concat(@cmd, Where), [host_local?: true]},
    {"init", Module.concat(@cmd, Init), [host_local?: true]},
    {"version", Module.concat(@cmd, Version), [host_local?: true]},
    {"self-update", Module.concat(@cmd, SelfUpdate), [host_local?: true]},
    {"upgrade", Module.concat(@cmd, SelfUpdate), [host_local?: true]},
    {"preflip-gate", Module.concat(@cmd, PreflipGate), []},
    {"grok-token", Module.concat(@cmd, GrokToken), []},
    {"help", ArbiterCli.Main, [host_local?: true]}
  ]

  # `arb dispatch <id>` == `arb ticket dispatch <id>`; same for `verify`.
  @shortcuts [{"dispatch", "dispatch"}, {"verify", "verify"}]

  # Pre-`arb <resource> <verb>` flat commands -> {resource, prefix}.
  @legacy [
    {"list", "ticket", ["list"]},
    {"show", "ticket", ["show"]},
    {"create", "ticket", ["create"]},
    {"close", "ticket", ["close"]},
    {"reopen", "ticket", ["reopen"]},
    {"claim", "ticket", ["claim"]},
    {"sync", "ticket", ["sync"]},
    {"ready", "ticket", ["ready"]},
    {"resume", "worker", ["resume"]},
    {"review", "worker", ["review"]},
    {"start", "server", ["start"]},
    {"restart", "server", ["restart"]},
    {"migrate", "server", ["migrate"]},
    {"doctor", "server", ["doctor"]},
    {"inbox", "message", ["inbox"]},
    {"notify", "message", ["notify"]},
    {"msg", "message", ["send"]},
    {"install-cli", "install", ["cli"]},
    {"install-service", "install", ["service"]}
  ]

  @doc "Flags `Main` consumes before any verb sees argv."
  @spec global_flags() :: [{String.t(), :boolean | :string}]
  def global_flags, do: @global_flags

  @doc "Every reachable verb: resources, shortcuts, and legacy flat commands."
  @spec all() :: [entry()]
  def all, do: resources() ++ shortcuts() ++ legacy()

  @doc """
  Handler modules that exist but no verb dispatches to any more
  (`Cmd.Review` — superseded by `worker review`; `Cmd.Update` — now a library
  behind `ticket update` / `server deploy`; `Main` still redirects the dual-mode
  flat `update` by hand).
  """
  @spec orphans() :: [entry()]
  def orphans do
    [
      entry("review", :orphan, Module.concat(@cmd, Review), deprecated: true),
      entry("update", :orphan, Module.concat(@cmd, Update), deprecated: true)
    ]
  end

  @doc "Names `AliasResolver` accepts as-is (everything but legacy flat verbs)."
  @spec known_verbs() :: [String.t()]
  def known_verbs do
    for %{kind: kind, name: name} <- all(), kind in [:resource, :shortcut], do: name
  end

  @doc "Look up an entry by the typed token (`:resource`/`:shortcut` first)."
  @spec fetch(String.t()) :: {:ok, entry()} | :error
  def fetch(name) do
    case Enum.find(all(), &(&1.name == name)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc "The argv a verb's handler receives, i.e. `entry.prefix ++ args`."
  @spec handler_args(entry(), [String.t()]) :: [String.t()]
  def handler_args(%{prefix: prefix}, args), do: prefix ++ args

  @doc "The `<resource> <verb>` spelling a legacy entry redirects to."
  @spec new_form(entry()) :: String.t()
  def new_form(%{redirect_to: res, prefix: prefix}), do: Enum.join([res | prefix], " ")

  defp resources do
    for {name, handler, opts} <- @resources, do: entry(name, :resource, handler, opts)
  end

  defp shortcuts do
    for {name, sub} <- @shortcuts do
      entry(name, :shortcut, Module.concat(@cmd, Issue), prefix: [sub])
    end
  end

  defp legacy do
    for {name, resource, prefix} <- @legacy do
      {:ok, %{handler: handler}} = fetch_resource(resource)

      entry(name, :legacy, handler, prefix: prefix, redirect_to: resource, deprecated: true)
    end
  end

  defp fetch_resource(name) do
    case Enum.find(resources(), &(&1.name == name)) do
      nil -> :error
      e -> {:ok, e}
    end
  end

  defp entry(name, kind, handler, opts) do
    %{
      name: name,
      kind: kind,
      handler: handler,
      prefix: Keyword.get(opts, :prefix, []),
      redirect_to: Keyword.get(opts, :redirect_to),
      deprecated: Keyword.get(opts, :deprecated, false),
      host_local?: Keyword.get(opts, :host_local?, false),
      flags: Keyword.get(opts, :flags, [])
    }
  end
end
