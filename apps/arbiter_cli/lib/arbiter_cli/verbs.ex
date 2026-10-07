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
    * `:probes` — argv prefixes (subcommand plus dummy positionals) that each
      reach a flag parser; `strictness_test.exs` appends an unknown flag to
      every one and asserts the verb exits 1 with
      `unknown option --x for arb <verb>`. Every verb must declare them (`nil`
      fails the test), so a new verb cannot ship with a lenient parse.
      `[]` is only for a verb with no flag surface at all (`help`).
  """

  @type entry :: %{
          name: String.t(),
          kind: :resource | :shortcut | :legacy | :orphan,
          handler: module(),
          prefix: [String.t()],
          redirect_to: String.t() | nil,
          deprecated: boolean(),
          host_local?: boolean(),
          flags: [{String.t(), :boolean | :string}],
          probes: [[String.t()]] | nil,
          workspace: :resolve | :none
        }

  # Flags stripped centrally in `Main` before any subcommand parses argv.
  @global_flags [
    {"--json", :boolean},
    {"--workspace", :string},
    {"-w", :string},
    {"--help", :boolean}
  ]

  @cmd ArbiterCli.Cmd

  @ticket_probes [
    ["list"],
    ["show", "bd-1"],
    ["create", "T"],
    ["update", "bd-1"],
    ["close", "bd-1"],
    ["reopen", "bd-1"],
    ["promote", "bd-1"],
    ["demote", "bd-1"],
    ["rank", "bd-1"],
    ["verify", "bd-1"],
    ["resolve", "bd-1"],
    ["handoff", "bd-1"],
    ["handback", "bd-1"],
    ["claim", "1"],
    ["sync"],
    ["ready"],
    ["dispatch", "bd-1"]
  ]

  @resources [
    {"ticket", Module.concat(@cmd, Issue), [workspace: :resolve, probes: @ticket_probes]},
    {"issue", Module.concat(@cmd, Issue),
     [workspace: :resolve, deprecated: true, probes: @ticket_probes]},
    {"epic", Module.concat(@cmd, Epic), [workspace: :none, probes: [["floor", "bd-1", "P1"]]]},
    {"worker", Module.concat(@cmd, Worker),
     [
       workspace: :resolve,
       probes: [
         ["list"],
         ["show", "bd-1"],
         ["runs", "bd-1"],
         ["log", "bd-1"],
         ["stop", "bd-1"],
         ["resume", "bd-1"],
         ["review", "bd-1"]
       ]
     ]},
    {"repo", Module.concat(@cmd, Repo), [workspace: :none, probes: [["list"], ["show", "r"]]]},
    {"dep", Module.concat(@cmd, Dep),
     [
       workspace: :resolve,
       probes: [["add", "a", "depends_on", "b"], ["rm", "a", "b"], ["list"]]
     ]},
    {"config", Module.concat(@cmd, Config),
     [workspace: :resolve, probes: [["get"], ["set", "k", "v"], ["unset", "k"], ["overview"]]]},
    {"server", Module.concat(@cmd, Server),
     [
       workspace: :none,
       probes: [["start"], ["restart"], ["deploy"], ["migrate"], ["doctor"], ["version"]]
     ]},
    {"workspace", Module.concat(@cmd, Workspace),
     [
       workspace: :resolve,
       probes: [
         ["list"],
         ["show", "w"],
         ["create", "w"],
         ["standing-order", "ls"],
         ["secret", "ls"]
       ]
     ]},
    {"message", Module.concat(@cmd, Message),
     [workspace: :resolve, probes: [["send", "r", "body"], ["inbox"], ["notify"]]]},
    {"usage", Module.concat(@cmd, Usage), [workspace: :resolve, probes: [[], ["events"]]]},
    {"loop", Module.concat(@cmd, Loop),
     [
       workspace: :resolve,
       probes: [
         ["analyze"],
         ["pending"],
         ["diff", "1"],
         ["apply", "1"],
         ["apply", "all"],
         ["reject", "1"],
         ["propose", "routing"],
         ["propose", "repo-doc-patch"],
         ["canary", "status"]
       ]
     ]},
    # Queue verbs address one task by id; the task already carries its workspace,
    # so there is no workspace dimension for `-w` to select.
    {"queue", Module.concat(@cmd, Queue),
     [
       workspace: :none,
       probes: [
         ["retry-auto-resolve", "bd-1"],
         ["restart-watchdog", "bd-1"],
         ["rerun-ci", "bd-1"]
       ]
     ]},
    {"scheduler", Module.concat(@cmd, Scheduler),
     [workspace: :none, probes: [["pause"], ["resume"], ["status"], ["wait"]]]},
    {"settings", Module.concat(@cmd, Settings),
     [workspace: :none, probes: [["get"], ["set", "k", "v"], ["unset", "k"], ["schema"]]]},
    {"quota", Module.concat(@cmd, Quota), [workspace: :resolve, probes: [[]]]},
    {"provider", Module.concat(@cmd, Provider),
     [workspace: :none, probes: [["pause", "p"], ["resume", "p"], ["list"]]]},
    {"breaker", Module.concat(@cmd, Breaker),
     [workspace: :resolve, probes: [["list"], ["reset", "sig"]]]},
    {"image", Module.concat(@cmd, Image),
     [workspace: :resolve, probes: [["list"], ["build", "r"], ["refresh"], ["prune"]]]},
    {"install", Module.concat(@cmd, Install),
     [workspace: :none, host_local?: true, probes: [["cli"], ["service"]]]},
    {"mcp", Module.concat(@cmd, Mcp),
     [workspace: :resolve, probes: [["token", "mint"], ["token", "verify", "tok"]]]},
    {"skill", Module.concat(@cmd, Skill),
     [
       workspace: :none,
       probes: [["list"], ["show", "s"], ["create", "s"], ["update", "s"], ["delete", "s"]]
     ]},
    {"session", Module.concat(@cmd, Session),
     [workspace: :none, host_local?: true, probes: [["list"], ["attach", "s"]]]},
    {"account", Module.concat(@cmd, Account),
     [
       workspace: :resolve,
       probes: [
         ["list"],
         ["show", "a"],
         ["create", "p", "s"],
         ["set", "a"],
         ["attach", "w", "p", "a"],
         ["detach", "w", "a"],
         ["rotate", "a"],
         ~w(merge a)
       ]
     ]},
    {"node", Module.concat(@cmd, Node),
     [
       workspace: :none,
       probes: [
         ["add"],
         ["list"],
         ["show", "n"],
         ["set", "n"],
         ["events", "n"],
         ["drain", "n"],
         ["undrain", "n"],
         ["revoke", "n"],
         ["upgrade", "n"],
         ["remove", "n"]
       ]
     ]},
    {"dashboard", Module.concat(@cmd, Dashboard), [workspace: :none, probes: [["login"]]]},
    {"prime", Module.concat(@cmd, Prime), [workspace: :resolve, probes: [[]]]},
    {"where", Module.concat(@cmd, Where), [workspace: :resolve, host_local?: true, probes: [[]]]},
    {"init", Module.concat(@cmd, Init), [workspace: :none, host_local?: true, probes: [[]]]},
    {"version", Module.concat(@cmd, Version),
     [workspace: :none, host_local?: true, probes: [[]]]},
    {"self-update", Module.concat(@cmd, SelfUpdate),
     [workspace: :none, host_local?: true, probes: [[]]]},
    {"upgrade", Module.concat(@cmd, SelfUpdate),
     [workspace: :none, host_local?: true, probes: [[]]]},
    {"preflip-gate", Module.concat(@cmd, PreflipGate), [workspace: :none, probes: [[]]]},
    {"grok-token", Module.concat(@cmd, GrokToken), [workspace: :none, probes: [[]]]},
    {"help", ArbiterCli.Main, [workspace: :none, host_local?: true, probes: []]}
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
      entry("review", :orphan, Module.concat(@cmd, Review),
        workspace: :resolve,
        deprecated: true,
        probes: [["bd-1"]]
      ),
      entry("update", :orphan, Module.concat(@cmd, Update),
        workspace: :resolve,
        deprecated: true,
        probes: [[], ["bd-1"]]
      )
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
      entry(name, :shortcut, Module.concat(@cmd, Issue),
        workspace: :resolve,
        prefix: [sub],
        probes: [[]]
      )
    end
  end

  defp legacy do
    for {name, resource, prefix} <- @legacy do
      {:ok, %{handler: handler, workspace: ws}} = fetch_resource(resource)

      entry(name, :legacy, handler,
        workspace: ws,
        prefix: prefix,
        redirect_to: resource,
        deprecated: true,
        probes: [[]]
      )
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
      flags: Keyword.get(opts, :flags, []),
      probes: Keyword.get(opts, :probes),
      workspace: Keyword.fetch!(opts, :workspace)
    }
  end
end
