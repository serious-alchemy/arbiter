defmodule Arbiter.Extension do
  @moduledoc """
  Behaviour for a package that adds implementations to Arbiter's policy seams.

  An extension is install-global: it is named once in release config and read
  at boot,

      config :arbiter, :extensions, [MyPackage.Extension]

  and `Arbiter.Extensions` merges what it contributes into each seam's
  registry. Which implementation a given workspace *uses* is still chosen per
  workspace, from `workspace.config` (`agent.type`, `tracker.type`,
  `merge.strategy`, `routing.policy`, `quota.gate`), at the point of use.
  Registration is the install's concern, selection is the workspace's.

  Arbiter's own in-tree adapters register through this same behaviour
  (`Arbiter.Extensions.Core`); nothing in the registry treats them specially.
  An extension can add keys but can never shadow one that is already
  registered (`docs/licensing-model.md` §6, additive-only).

  ## Seams

  `contributions/0` returns `{seam, key, module}` triples. `seam` is one of
  `Arbiter.Extensions.seams/0`:

  | seam                | module must implement           |
  |---------------------|---------------------------------|
  | `:agent`            | `Arbiter.Agents.Agent`          |
  | `:tracker`          | `Arbiter.Trackers.Tracker`      |
  | `:merger`           | `Arbiter.Mergers.Merger`        |
  | `:routing_policy`   | `Arbiter.Agents.Routing.Policy` |
  | `:quota_gate`       | `Arbiter.Quota.Gate`            |
  | `:session_provider` | `Arbiter.Sessions.Provider`     |
  | `:mcp_agent_config` | `Arbiter.MCP.AgentConfig`       |
  | `:quota_snapshot`   | `Arbiter.Quota.Gate.Snapshot.Source` |

  `key` is the string a workspace config (or the persisted provider/type
  column) uses to name the implementation. It is also the registry's atom key,
  so keep it short and lower_snake_case. Boot fails when a contributed module
  does not export every non-optional callback of its seam's behaviour, when
  the seam is unknown, or when the `{seam, key}` pair is already taken.

  A provider bundle (a new agent CLI) contributes the same key to `:agent`,
  `:mcp_agent_config`, and, when it runs in a coordinator pane,
  `:session_provider`. If it keeps its own quota table it also contributes a
  `:quota_snapshot` source, keyed by the quota struct's module name
  (`Atom.to_string(MyApp.FooQuota)`), so its rows are visible to the quota gate.
  """

  @typedoc "A seam name; see the table in the moduledoc."
  @type seam ::
          :agent
          | :tracker
          | :merger
          | :routing_policy
          | :quota_gate
          | :session_provider
          | :mcp_agent_config
          | :quota_snapshot

  @doc "The implementations this extension adds, as `{seam, key, module}`."
  @callback contributions() :: [{seam(), key :: String.t(), module()}]

  @doc """
  MCP tools this extension adds (`Arbiter.MCP.Catalog` tool maps).

  Collected by `Arbiter.Extensions.mcp_tools/0` and merged into
  `Arbiter.MCP.Catalog` (`visible/1`, `fetch/1`, `call/3`). Each map needs
  `:name`, `:description`, `:input_schema`, `:tiers` (a non-empty subset of
  `[:worker, :coordinator]`) and a 2-arity `:handler`. Boot fails on a
  malformed tool or a name already taken by a core tool, a deprecated alias,
  or another extension. A refine-tier session never sees extension tools
  until `Arbiter.MCP.RefinePolicy` decides them.
  """
  @callback mcp_tools() :: [map()]

  @optional_callbacks mcp_tools: 0
end
