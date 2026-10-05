defmodule Arbiter.Agents do
  @moduledoc """
  Entry point for autonomous-agent dispatch.

  Reads a workspace's `config["agent"]["type"]`, resolves the
  `Arbiter.Agents.Agent` adapter, and hands back the module. Callers should
  resolve through this dispatcher rather than referencing
  `Arbiter.Agents.Claude` directly — keeps adapter resolution centralized
  so workspace defaults and per-task overrides behave consistently.

  Mirrors `Arbiter.Trackers` and `Arbiter.Mergers`. Phase B of the harness
  design (`docs/agent-harness-design.md`) intentionally ships only the
  `Claude` adapter — the seam exists so a future adapter (Codex / Aider /
  Gemini) can land without touching the worker or the ReviewGate.

  ## Resolution rule

  `workspace.config["agent"]["type"]` is a string or a list of strings from
  `valid_agent_types/0`. Missing key falls back to `:claude` so existing
  workspaces see unchanged behavior. When the value is a list (multi-provider
  pool), `Arbiter.Agents.ProviderPool` picks the first healthy provider; a
  provider is unhealthy while its circuit-breaker cooldown is active.

  ## Reviewer dispatch

  The ReviewGate's reviewer is a separate role with its own adapter slot
  under `config["review_agent"]`. Same shape as `config["agent"]`. Falls
  back to the worker agent's adapter (so a workspace that names
  `agent.type = "claude"` and omits `review_agent` gets a Claude reviewer
  automatically).
  """

  alias Arbiter.Agents.Claude
  alias Arbiter.Agents.ProviderConstraint
  alias Arbiter.Agents.ProviderPool
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @type adapter :: module()

  @doc """
  Returns the adapter module for the given workspace.

  Resolves the agent type from `config["agent"]["type"]` (or `:claude` if
  unset) and looks it up in `adapters/0`.
  """
  @spec for_workspace(Workspace.t() | nil) :: adapter
  def for_workspace(nil), do: Claude
  def for_workspace(%Workspace{} = ws), do: for_type(agent_type(ws, :agent))

  @doc """
  Returns the reviewer adapter for the given workspace. Falls back to the
  worker agent's adapter when `review_agent` is not configured.
  """
  @spec reviewer_for_workspace(Workspace.t() | nil) :: adapter
  def reviewer_for_workspace(nil), do: Claude
  def reviewer_for_workspace(%Workspace{} = ws), do: for_type(reviewer_type(ws))

  @doc """
  The reviewer role's preferred provider type atom — same resolution as
  `reviewer_for_workspace/1`, but the atom rather than the module, so
  strict-mode write-confinement re-selection (bd-1abj7u) can compare it
  against `reviewer_pool/1` without a reverse lookup through `adapters/0`.
  """
  @spec reviewer_type(Workspace.t() | nil) :: atom()
  def reviewer_type(nil), do: :claude

  def reviewer_type(%Workspace{} = ws) do
    agent_type(ws, :review_agent) || agent_type(ws, :agent) || :claude
  end

  @doc """
  Returns the reviewer role's configured provider pool, in **configured order**.

  `review_agent.type` may be a single string or a list of strings; a workspace
  with no `review_agent` block falls back to the worker `agent` block (mirroring
  `reviewer_for_workspace/1`), and a workspace with neither yields the `:claude`
  default. Unrecognized type strings are dropped.

  Unlike `reviewer_for_workspace/1` this deliberately does NOT consult
  `Arbiter.Agents.ProviderPool` — a caller that rotates THROUGH the pool (the
  ReviewGate's reviewer print-timeout rotation, bd-3hb4ih) needs the full
  configured order, not just the first healthy entry.
  """
  @spec reviewer_pool(Workspace.t() | nil) :: [atom()]
  def reviewer_pool(nil), do: [:claude]

  def reviewer_pool(%Workspace{config: config}) do
    case configured_types(config, :review_agent) do
      [] ->
        case configured_types(config, :agent) do
          [] -> [:claude]
          types -> types
        end

      types ->
        types
    end
  end

  @doc """
  Returns the worker `:agent` role's configured provider pool, in
  **configured order**. Mirrors `reviewer_pool/1`'s shape for the worker
  role: `agent.type` may be a single string or a list; `[:claude]` when
  unset or with no workspace.

  Used by strict-mode write-confinement re-selection (bd-1abj7u) to name the
  full set of configured alternatives when the routing policy's first choice
  can't confine writes to the worktree.
  """
  @spec agent_pool(Workspace.t() | nil) :: [atom()]
  def agent_pool(nil), do: [:claude]

  def agent_pool(%Workspace{config: config}) do
    case configured_types(config, :agent) do
      [] -> [:claude]
      types -> types
    end
  end

  @doc """
  Whether `adapter` can confine writes to the worktree under `policy`
  (bd-1abj7u). Delegates to the adapter's optional `write_confinement/1`
  callback; `:none` (never confined) when the adapter omits it.
  """
  @spec write_confinement(adapter, SecurityPolicy.t()) :: :os_jail | :permission_layer | :none
  def write_confinement(adapter, %SecurityPolicy{} = policy) when is_atom(adapter) do
    # `function_exported?/3` does NOT autoload — an adapter this process
    # hasn't called into yet reads as "callback missing" even when its BEAM
    # plainly exports it, misreporting `:none` for a real adapter. The
    # `Code.ensure_loaded?/1` guard (same idiom as every other optional-callback
    # check in this codebase — see `Preflight`, `Trackers`, `Worker`) makes this
    # security-gating check independent of incidental load order elsewhere in
    # the process.
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :write_confinement, 1) do
      adapter.write_confinement(policy)
    else
      :none
    end
  end

  @doc """
  Whether `adapter` can confine a worker's network egress under `policy` on this
  host (G11, design §3.4). Delegates to the adapter's optional
  `egress_confinement/1` callback; `:none` when the adapter omits it.
  """
  @spec egress_confinement(adapter, SecurityPolicy.t()) :: :os_jail | :none
  def egress_confinement(adapter, %SecurityPolicy{} = policy) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :egress_confinement, 1) do
      adapter.egress_confinement(policy)
    else
      :none
    end
  end

  @doc "Whether `write_confinement/2` answers anything other than `:none`."
  @spec write_confined?(adapter, SecurityPolicy.t()) :: boolean()
  def write_confined?(adapter, %SecurityPolicy{} = policy) do
    write_confinement(adapter, policy) != :none
  end

  @doc """
  Why `adapter`'s `write_confinement/2` degraded under `policy` (bd-3s82pf),
  or `nil` when there is nothing to warn about. Delegates to the adapter's
  optional `write_jail_warning/1` callback; `nil` when the adapter omits it.
  """
  @spec write_jail_warning(adapter, SecurityPolicy.t()) :: String.t() | nil
  def write_jail_warning(adapter, %SecurityPolicy{} = policy) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :write_jail_warning, 1) do
      adapter.write_jail_warning(policy)
    end
  end

  @doc """
  Resolve an eligible provider type for a `:strict`-scoped dispatch.

  `preferred` is the type the caller's own routing/reviewer resolution
  already picked; `pool` is the full configured set of alternatives for that
  role (`agent_pool/1` or `reviewer_pool/1`).

  - Any mode other than `:strict` is unconstrained: always `{:ok, preferred}`.
  - Under `:strict`, `preferred` is used when it can confine writes
    (`write_confined?/2`).
  - Otherwise, when `opts[:explicit]` is true (the caller named this
    provider directly — `arb dispatch --provider`, a pinned reviewer
    rotation), there is no silent substitution: `{:error, :ineligible}`.
  - Otherwise (automatic selection), the first OTHER pool entry that can
    confine writes is used instead. `{:error, :ineligible}` only when none
    of the configured pool can.

  Never silently downgrades the mode and never hands back an ineligible
  provider under `:strict` — the caller turns `{:error, :ineligible}` into
  the fail-closed refusal named for the operator (`Arbiter.Worker.Dispatch`).
  """
  @spec strict_eligible_provider(atom(), SecurityPolicy.t(), [atom()], keyword()) ::
          {:ok, atom()} | {:error, :ineligible}
  def strict_eligible_provider(preferred, policy, pool \\ [], opts \\ [])

  def strict_eligible_provider(
        preferred,
        %SecurityPolicy{permissions: %{mode: :strict}} = policy,
        pool,
        opts
      ) do
    cond do
      write_confined?(for_type(preferred), policy) ->
        {:ok, preferred}

      Keyword.get(opts, :explicit, false) ->
        {:error, :ineligible}

      true ->
        pool
        |> Enum.filter(&Map.has_key?(adapters(), &1))
        |> Enum.find(&(&1 != preferred and write_confined?(for_type(&1), policy)))
        |> case do
          nil -> {:error, :ineligible}
          alt -> {:ok, alt}
        end
    end
  end

  def strict_eligible_provider(preferred, _policy, _pool, _opts), do: {:ok, preferred}

  @doc """
  Returns the adapter module for a task.

  Today there's no per-task override (no `Issue.agent_type` column yet —
  see `docs/agent-harness-design.md` §4.2 Stage 2). For now the task
  inherits the workspace's adapter. The signature accepts the task +
  workspace so callers don't change when the per-task override lands.
  """
  @spec for_task(Issue.t(), Workspace.t() | nil) :: adapter
  def for_task(%Issue{}, workspace), do: for_workspace(workspace)

  @doc """
  Returns the adapter module for an agent type atom.

  Raises if the type has no adapter registered (i.e. a type the codebase
  knows about but hasn't shipped yet — same shape as `Arbiter.Trackers`).
  """
  @spec for_type(atom()) :: adapter
  def for_type(type) when is_atom(type) do
    case Map.fetch(adapters(), type) do
      {:ok, mod} ->
        mod

      :error ->
        raise ArgumentError,
              "no agent adapter registered for #{inspect(type)} " <>
                "(registered: #{inspect(Map.keys(adapters()))})"
    end
  end

  @doc """
  Returns the map of agent_type → adapter module: core's adapters plus any
  installed `Arbiter.Extension`'s (`Arbiter.Extensions.registry/1`).
  """
  @spec adapters() :: %{atom() => adapter}
  def adapters, do: Arbiter.Extensions.registry(:agent)

  @doc """
  Check whether an agent provider is currently available to run.
  Returns false if the adapter is unknown, its credentials are flagged expired,
  or the provider is paused (`Arbiter.Providers.Pause`).
  """
  @spec provider_available?(atom()) :: boolean()
  def provider_available?(provider) when is_atom(provider) do
    case Map.get(adapters(), provider) do
      nil ->
        false

      adapter ->
        not Arbiter.Agents.CredentialWatchdog.expired?(adapter) and
          not Arbiter.Providers.Pause.provider_paused?(provider)
    end
  end

  @doc """
  Resolve the provider to use for a revision, resume, or fix pass on `task_id`.

  Reads the provider from the most recent authoring run via
  `Arbiter.Workers.Run.latest_authoring_provider/1`. If that provider is
  available, returns `{provider, nil}`.

  If the original provider cannot be used (e.g. credentials flagged expired,
  or the recorded provider atom is no longer a recognized adapter), it falls
  back to an available provider and returns
  `{fallback_provider, fallback_reason}` so the fallback is visible and recorded.

  If no prior run exists, falls back to the workspace default `{default_provider, nil}`.

  If NO other provider is available either, this does NOT silently hand back
  the known-unavailable original provider under a "fell back" reason that
  would misreport what actually happened — it still returns the original
  provider (there is nothing else to spawn with), but the `fallback_reason`
  says plainly that no alternative was available, so the caller/coordinator
  isn't told a fallback succeeded when it didn't.

  `constraint` (bd-13pqcp) is the ticket's `Arbiter.Agents.ProviderConstraint`.
  A provider it does not allow is treated as unavailable: the resolution moves to
  an allowed one, and with none, hands the excluded provider back under a reason
  naming the constraint for the spawn site's `ProviderConstraint.check/2` to
  refuse. `nil` (the default) is exactly the behaviour above.
  """
  @spec resolve_revision_provider(
          String.t(),
          Workspace.t() | nil,
          Arbiter.Agents.ProviderConstraint.t() | nil
        ) ::
          {provider :: atom(), fallback_reason :: String.t() | nil}
  def resolve_revision_provider(task_id, workspace, constraint \\ nil) when is_binary(task_id) do
    case Arbiter.Workers.Run.latest_authoring_provider(task_id) do
      orig when is_atom(orig) and not is_nil(orig) ->
        resolve_authoring_provider(orig, workspace, constraint)

      nil ->
        default = default_agent_type(workspace)

        if ProviderConstraint.allows?(constraint, default) do
          {default, nil}
        else
          constrained_fallback(workspace, default, constraint)
        end
    end
  end

  defp resolve_authoring_provider(orig, workspace, constraint) do
    cond do
      not ProviderConstraint.allows?(constraint, orig) ->
        constrained_fallback(workspace, orig, constraint)

      provider_available?(orig) ->
        {orig, nil}

      true ->
        case fallback_for_workspace(workspace, orig, constraint) do
          {:ok, fallback} ->
            {fallback, "fell back from #{orig}: #{unavailable_cause(orig)}"}

          :error ->
            {orig,
             "no provider available: #{orig} #{unavailable_cause(orig)} and no alternative adapter is available; retrying #{orig}"}
        end
    end
  end

  # bd-13pqcp: `orig` (the authoring provider, or the workspace default) is
  # excluded by the ticket's provider constraint. Move to an allowed, available
  # provider and say so; with none, hand `orig` back with a reason that names the
  # constraint — the spawn site's `ProviderConstraint.check/2` then refuses it,
  # so the work waits rather than running on an excluded provider.
  defp constrained_fallback(workspace, orig, constraint) do
    detail = ProviderConstraint.describe(constraint)

    case fallback_for_workspace(workspace, orig, constraint) do
      {:ok, fallback} ->
        {fallback, "fell back from #{orig}: provider constraint (#{detail})"}

      :error ->
        {orig,
         "no provider available: #{orig} is excluded by the provider constraint (#{detail}) " <>
           "and no allowed adapter is available"}
    end
  end

  defp unavailable_cause(provider) do
    case Arbiter.Providers.Pause.for_provider(provider) do
      nil -> "credentials flagged expired"
      pause -> "paused: #{pause.reason || "no reason given"}"
    end
  end

  defp default_agent_type(%Workspace{} = ws), do: agent_type(ws, :agent) || :claude
  defp default_agent_type(nil), do: :claude

  defp fallback_for_workspace(%Workspace{} = ws, orig, constraint) do
    pool = configured_types(ws.config, :agent)
    first_available((pool ++ [:claude, :gemini, :codex]) |> Enum.uniq(), orig, constraint)
  end

  defp fallback_for_workspace(nil, orig, constraint),
    do: first_available([:claude, :gemini, :codex], orig, constraint)

  defp first_available(candidates, orig, constraint) do
    candidates
    |> then(&ProviderConstraint.filter(constraint, &1))
    |> Enum.find(fn t -> t != orig and provider_available?(t) end)
    |> case do
      nil -> :error
      t -> {:ok, t}
    end
  end

  @doc "Returns the list of valid agent type strings (for workspace-config validation)."
  @spec valid_agent_types() :: [String.t()]
  def valid_agent_types, do: Arbiter.Extensions.keys(:agent)

  @doc """
  Prepare the current process to make adapter calls for `workspace`.

  Seeds the adapter's per-process config (mirror of `Trackers.prepare/2`
  and `Mergers.prepare/1`) so subsequent `default_argv/2` / `spawn_env/1`
  calls in this process see the workspace's model + api_keys without
  threading the workspace through every call site.

  `role_or_opts` can be `:agent` (default), `:review_agent`, or a keyword list of options
  passed to the adapter's `prepare/2` callback.

  Both roles share the same adapter machinery and the same per-process
  config dict — only one role's config can be active in a process at a
  time. The ReviewGate seeds `:review_agent` before spawning the reviewer
  session; the worker seeds `:agent` before spawning the worker.

  A `nil` workspace clears the per-process config (back to CLI defaults
  + ambient env auth). A no-op for unconfigured adapters.
  """
  @spec prepare(Workspace.t() | nil, :agent | :review_agent | keyword()) :: :ok
  def prepare(workspace, role_or_opts \\ :agent)

  def prepare(workspace, role) when role in [:agent, :review_agent] do
    prepare(workspace, role: role)
  end

  def prepare(workspace, opts) when is_list(opts) do
    for {_type, adapter} <- adapters() do
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :prepare, 2) do
        adapter.prepare(workspace, opts)
      end
    end

    :ok
  end

  # ---- Internals --------------------------------------------------------

  @doc "Returns the resolved agent type atom for the given workspace and role (:agent or :review_agent)."
  @spec agent_type(Workspace.t() | nil, atom()) :: atom() | nil
  def agent_type(workspace, role)

  def agent_type(%Workspace{config: config}, role) do
    case get_in(config || %{}, [Atom.to_string(role), "type"]) do
      type when is_binary(type) ->
        safe_type_atom(type)

      types when is_list(types) ->
        types
        |> Enum.map(&safe_type_atom/1)
        |> Enum.reject(&is_nil/1)
        |> ProviderPool.pick()

      _ when role == :agent ->
        :claude

      _ ->
        nil
    end
  end

  def agent_type(nil, :agent), do: :claude
  def agent_type(nil, _role), do: nil

  # The type strings configured for `role`, mapped to adapter atoms in the order
  # they were written, with unrecognized entries dropped. A single string is a
  # one-entry pool. Shared by `reviewer_pool/1`; `agent_type/2` above keeps its
  # own (health-aware, single-answer) resolution.
  #
  # `safe_type_atom/1` is NOT sufficient on its own here: it only proves the
  # atom exists somewhere in the VM, not that it names an adapter, so a typo'd
  # `"nope"` can survive it whenever anything else in the system has ever used
  # that atom. Every entry is checked against the adapter registry, because a
  # pool entry is handed straight to `for_type/1`, which raises on an
  # unregistered type.
  defp configured_types(config, role) do
    case get_in(config || %{}, [Atom.to_string(role), "type"]) do
      type when is_binary(type) -> registered_types([type])
      types when is_list(types) -> registered_types(types)
      _ -> []
    end
  end

  defp registered_types(types) do
    types
    |> Enum.map(&safe_type_atom/1)
    |> Enum.filter(&Map.has_key?(adapters(), &1))
  end

  defp safe_type_atom(t) when is_binary(t) do
    String.to_existing_atom(t)
  rescue
    ArgumentError -> nil
  end

  defp safe_type_atom(_), do: nil
end
