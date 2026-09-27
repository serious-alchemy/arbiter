defmodule Arbiter.Agents.ProviderRouting do
  @moduledoc """
  Implementer provider routing by **most quota left** (bd-40pzpj, phase 1 of
  bd-9ck2a7): at dispatch, the implementer goes to the workspace's provider
  account with the most quota headroom against its pace, instead of the first
  healthy `agent.type` (`Arbiter.Agents.ProviderPool`).

  ## Opt-in, per workspace

  `routing.provider_selection: most_quota` turns it on. Unset (or
  `"failover"`) is today's behaviour exactly — nothing here runs, nothing is
  recorded. It ships **off** everywhere: the operator's condition is that no
  workspace turns it on until the agy write jail lands (bd-5gvqgc, bd-3s82pf).

  ## Candidates

  The workspace's attached provider accounts that its provider settings
  (`Arbiter.Accounts.ProviderSettings`, bd-64apru) allow for the
  **implementer** role, in their configured order. An account linked only for
  metering or for the reviewer is not a candidate, and a workspace with no
  implementer attachment has no candidates at all (its `agent.type` fallback
  is not an account set). Each candidate is classified by
  `Arbiter.Agents.ModelFamily` from its provider and the model difficulty
  routing would run on it (`ModelFamily.model_for_tier/3`), which is also what
  picks agy's quota pool.

  ## Availability

  A candidate is dropped, with its reason recorded, when any of these hold
  (checked in this order):

    * `disabled` / `merged` — the account is parked or merged away;
    * `no_adapter` — its provider has no agent adapter;
    * `cli_unavailable` — a Google account (`antigravity` / `gemini_cli`)
      whose CLI is not the one the `gemini` adapter would spawn on this host;
    * `auth_expired` — `Arbiter.Agents.AuthHold` is open, or
      `Arbiter.Agents.CredentialWatchdog` holds the adapter's credential
      expired. agy and Codex authenticate through their CLI logins, so a
      healthy probe is all they need — no account credential row is required
      of any candidate;
    * `circuit_broken` — `ProviderPool.healthy?/1` is false;
    * `at_capacity` — `Arbiter.Accounts.Concurrency.account_headroom/3` is 0:
      the account is at `max_concurrent` or at this workspace's share. For
      every role but `:main` the task's own live workers are left out of the
      count (`exclude_task:`): the role replaces them rather than running
      beside them — the author worker parked through a ReviewGate round
      still holds its registry slot, and counting it would drop the pin for
      a slot it is not using;
    * `write_confinement_none` — the scope is `:strict` and the adapter's
      `write_confinement/1` (bd-1abj7u) is `:none`. An adapter that does not
      implement the callback answers `:none`;
    * `quota_held` — the workspace's `Arbiter.Quota.Gate` would hold a
      dispatch on this account's snapshot (account ∧ workspace policy, paced
      included) for the model it would run.

  ## Ranking

  The survivors are ranked by `Arbiter.Quota.Headroom.binding/3` —
  `threshold_now − used` on the binding window, where `threshold_now` is the
  gate's own paced or flat ceiling composed `min(account, workspace)` — most
  headroom first, ties to configured order, accounts with no reading after
  every known one.

  ## The pin, fallback and override

  The first routed dispatch pins the chosen account and family on the task
  (`implementer_account_id` / `implementer_family`). Every implementer role
  after it — resumes, ReviewGate implementer rounds, CI fix passes, conflict
  resolvers, reconciler resumes — reuses the pin while it is available. When
  it is not, the role falls back at once to the best available account,
  excluding the reviewer's model family when another option exists
  (bd-a1ke2c), and the decision records the fallback. The pin is kept.

  A dispatch-time provider override wins: it is recorded as an override,
  alongside the headroom evaluation, and pins nothing.

  With no candidate available the dispatch goes ahead exactly as it would
  have without routing, and the decision says so (`outcome: "no_candidate"`).

  ## The decision record

  `select/4` returns a JSON-safe, string-keyed map the run stores in
  `worker_runs.routing_decision`: `mode`, `role`, `outcome` (`selected` /
  `pinned` / `fallback` / `override` / `no_candidate`), the chosen
  `account_id` / `account_slug` / `provider` / `agent_type` / `family` /
  `pool` / `model` / `model_tier` / `headroom`, the ranked `candidates` with
  their headroom, the `dropped` candidates with `reason` and `detail`, and
  `fallback` / `override` / `excluded_family` / `pinned_account_id` when they
  apply.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Accounts.Concurrency
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderSettings
  alias Arbiter.Agents
  alias Arbiter.Agents.AuthHold
  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Agents.ProviderPool
  alias Arbiter.Agents.Routing
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Quota.Headroom
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workers.Run

  @selections ~w(failover most_quota)
  @max_fallback_length 255

  @type role :: atom()
  @type decision :: %{String.t() => term()}
  @type selection :: %{
          agent_type: atom(),
          account: ProviderAccount.t() | nil,
          family: ModelFamily.family() | nil,
          decision: decision()
        }

  @doc "Valid `routing.provider_selection` values (for workspace-config validation)."
  @spec valid_selections() :: [String.t()]
  def valid_selections, do: @selections

  @doc "Whether `workspace` routes its implementer by most quota left."
  @spec enabled?(Workspace.t() | nil) :: boolean()
  def enabled?(%Workspace{config: config}),
    do: get_in(config || %{}, ["routing", "provider_selection"]) == "most_quota"

  def enabled?(_), do: false

  @doc """
  Evaluate every implementer candidate for `task`: the ranked available ones
  (`"candidates"`) and the dropped ones with their reasons (`"dropped"`).

  Options (all optional; the defaults read the live system):

    * `:security` — the dispatch's resolved `SecurityPolicy` (default: the
      workspace's);
    * `:now`;
    * `:quota_fun` — `(ProviderAccount.t() -> quota row | nil)`;
    * `:gemini_code` — which Google CLI the `gemini` adapter would spawn;
    * `:write_confinement` — `(adapter, policy -> atom)`;
    * `:role` — the role being routed (default `:main`; `select/4` sets it),
      which decides whether the task's own live workers count toward
      `at_capacity`.
  """
  @spec evaluate(Workspace.t(), Issue.t() | nil, keyword()) :: decision()
  def evaluate(%Workspace{} = ws, task, opts \\ []) do
    ws |> run_evaluation(task, opts) |> elem(0)
  end

  # The record, plus the available (ranked) and dropped entries behind it.
  defp run_evaluation(ws, task, opts) do
    ctx = context(ws, task, opts)

    {available, dropped} =
      ws
      |> candidates()
      |> Enum.with_index()
      |> Enum.map(fn {candidate, index} -> check(entry(candidate, index, ctx), ctx) end)
      |> Enum.split_with(&match?({:ok, _}, &1))

    available = available |> Enum.map(&elem(&1, 1)) |> rank()
    dropped = Enum.map(dropped, &elem(&1, 1))

    record = %{
      "mode" => "most_quota",
      "candidates" => Enum.map(available, &candidate_record/1),
      "dropped" => Enum.map(dropped, &drop_record/1),
      "evaluated_at" => DateTime.to_iso8601(ctx.now),
      "model_tier" => ctx.tier
    }

    {record, available, dropped}
  end

  @doc """
  Choose the implementer account for `task` in `role` (`:main`, `:resume`,
  `:fix_pass`, …). `{:ok, selection}` names the adapter type to spawn and the
  decision to record; `{:legacy, decision}` means no candidate is available
  and the caller keeps its pre-routing resolution.

  Options: those of `evaluate/3`, plus `:override` (an explicit adapter
  type), `:reviewer_family` (default: the task's latest review run's) and
  `:pin` (default `true`).
  """
  @spec select(Workspace.t(), Issue.t(), role(), keyword()) ::
          {:ok, selection()} | {:legacy, decision()}
  def select(%Workspace{} = ws, %Issue{} = task, role, opts \\ []) do
    {record, entries, dropped} = run_evaluation(ws, task, Keyword.put(opts, :role, role))
    base = Map.put(record, "role", to_string(role))

    case Keyword.get(opts, :override) do
      override when is_atom(override) and not is_nil(override) ->
        override(base, entries, ws, override)

      _ ->
        choose(base, entries, dropped, task, opts)
    end
  end

  @doc """
  The provider an implementer role on `task` runs with —
  `{provider, fallback_reason, decision}`.

  Off (`enabled?/1` false): exactly `Arbiter.Agents.resolve_revision_provider/2`
  (or the `:override`), with a `nil` decision. On: the pin, a recorded
  fallback, or — with no candidate available — the same pre-routing
  resolution, with the decision recording why.

  `fallback_reason` is meant for the run's `provider_fallback`; see
  `escalate_fallback?/1` for whether it warrants the coordinator's attention.
  """
  @spec implementer_provider(Issue.t() | String.t(), Workspace.t() | nil, role(), keyword()) ::
          {atom(), String.t() | nil, decision() | nil}
  def implementer_provider(task, workspace, role, opts \\ [])

  def implementer_provider(task_id, workspace, role, opts) when is_binary(task_id) do
    with true <- enabled?(workspace),
         {:ok, %Issue{} = task} <- Ash.get(Issue, task_id) do
      implementer_provider(task, workspace, role, opts)
    else
      _ -> legacy(task_id, workspace, opts)
    end
  end

  def implementer_provider(%Issue{} = task, workspace, role, opts) do
    if enabled?(workspace) do
      case select(workspace, task, role, opts) do
        {:ok, selection} ->
          {selection.agent_type, selection.decision["fallback"], selection.decision}

        {:legacy, decision} ->
          {provider, fallback} = legacy_resolution(task.id, workspace, opts)
          {provider, fallback, Map.put(decision, "agent_type", to_string(provider))}
      end
    else
      legacy(task.id, workspace, opts)
    end
  rescue
    e ->
      Logger.warning("ProviderRouting: routing #{task.id} crashed: #{Exception.message(e)}")
      legacy(task.id, workspace, opts)
  end

  @doc """
  Whether a `fallback_reason` from `implementer_provider/4` is the
  pre-routing credential fallback the coordinator is told about — as opposed
  to a routing fallback off an unavailable pin, which is routine under
  `most_quota` and is recorded on the run only.
  """
  @spec escalate_fallback?(decision() | nil) :: boolean()
  def escalate_fallback?(nil), do: true
  def escalate_fallback?(%{"outcome" => "no_candidate"}), do: true
  def escalate_fallback?(_decision), do: false

  @doc """
  Worker-meta fields for a decision: the decision itself plus the flat
  `provider_account_id` / `model_family` the run row is indexed by, and the
  fallback (truncated to the run column's width). `%{}` for `nil`.
  """
  @spec run_meta(decision() | nil) :: map()
  def run_meta(nil), do: %{}

  def run_meta(%{} = decision) do
    %{
      routing_decision: decision,
      provider_account_id: decision["account_id"],
      model_family: decision["family"]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc "A fallback reason trimmed to fit `worker_runs.provider_fallback`."
  @spec truncate_fallback(String.t() | nil) :: String.t() | nil
  def truncate_fallback(nil), do: nil

  def truncate_fallback(reason) when is_binary(reason) do
    if String.length(reason) > @max_fallback_length,
      do: String.slice(reason, 0, @max_fallback_length - 1) <> "…",
      else: reason
  end

  # ---- selection ------------------------------------------------------------

  defp override(base, entries, ws, override) do
    type = to_string(override)
    entry = Enum.find(entries, &(&1.agent_type == type)) || override_entry(ws, override)

    decision =
      base
      |> put_chosen(entry, override)
      |> Map.merge(%{
        "outcome" => "override",
        "override" => "dispatch-time provider override: #{type}"
      })

    {:ok, selection(override, entry, decision)}
  end

  # The override's own account when it is a candidate that was dropped (or not
  # a candidate at all): the account the workspace meters that provider under.
  defp override_entry(ws, override) do
    case ws.id |> Arbiter.Quota.account_id(override) |> Arbiter.Accounts.Resolver.get() do
      %ProviderAccount{} = account ->
        %{family: family, pool: pool} = ModelFamily.classify(account.provider, nil)

        %{
          account: account,
          agent_type: to_string(override),
          family: family,
          pool: pool,
          model: nil
        }

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp choose(base, entries, dropped, task, opts) do
    case pinned(task, entries, dropped) do
      {:pinned, entry} ->
        {:ok, selection(entry, Map.put(put_chosen(base, entry), "outcome", "pinned"))}

      {:unavailable, why} ->
        fallback(base, entries, task, why, opts)

      :none ->
        first(base, entries, task, opts)
    end
  end

  defp first(base, [], _task, _opts), do: no_candidate(base, nil)

  defp first(base, [best | _], task, opts) do
    if Keyword.get(opts, :pin, true), do: pin(task, best)
    {:ok, selection(best, Map.put(put_chosen(base, best), "outcome", "selected"))}
  end

  defp fallback(base, entries, task, why, opts) do
    reviewer = Keyword.get_lazy(opts, :reviewer_family, fn -> reviewer_family(task.id) end)
    others = Enum.reject(entries, &(reviewer && &1.family == reviewer))

    {pool, excluded} =
      if others != [] and others != entries,
        do: {others, reviewer && to_string(reviewer)},
        else: {entries, nil}

    base =
      Map.merge(base, %{
        "pinned_account_id" => task.implementer_account_id,
        "excluded_family" => excluded
      })

    case pool do
      [] ->
        no_candidate(base, why)

      [best | _] ->
        reason = truncate_fallback("#{why}; fell back to #{label(best.account)}")

        decision =
          base
          |> put_chosen(best)
          |> Map.merge(%{"outcome" => "fallback", "fallback" => reason})

        {:ok, selection(best, decision)}
    end
  end

  defp no_candidate(base, why) do
    reason =
      [why, "no implementer account available; dispatching on the pre-routing provider"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("; ")

    {:legacy,
     Map.merge(base, %{"outcome" => "no_candidate", "fallback" => truncate_fallback(reason)})}
  end

  defp pinned(%Issue{implementer_account_id: nil}, _entries, _dropped), do: :none

  defp pinned(%Issue{implementer_account_id: id}, entries, dropped) do
    case Enum.find(entries, &(&1.account.id == id)) do
      %{} = entry ->
        {:pinned, entry}

      nil ->
        # Why it is not available: its drop reason, or that it is no longer an
        # implementer candidate at all.
        case Enum.find(dropped, &(&1.account.id == id)) do
          %{} = entry ->
            {:unavailable,
             "pinned account #{label(entry.account)} unavailable (#{drop_text(entry)})"}

          nil ->
            {:unavailable,
             "pinned account #{id |> pinned_account() |> label()} unavailable " <>
               "(no longer allowed for the implementer role)"}
        end
    end
  end

  defp drop_text(%{reason: reason, detail: nil}), do: reason
  defp drop_text(%{reason: reason, detail: detail}), do: "#{reason}: #{detail}"

  defp pinned_account(id) do
    Arbiter.Accounts.Resolver.get(id)
  rescue
    _ -> nil
  end

  defp pin(%Issue{} = task, %{account: account, family: family}) do
    task
    |> Ash.Changeset.for_update(:pin_implementer, %{
      implementer_account_id: account.id,
      implementer_family: family && to_string(family)
    })
    |> Ash.update()
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("ProviderRouting: could not pin #{task.id}: #{inspect(reason)}")
        :ok
    end
  end

  defp selection(entry, decision) do
    selection(String.to_existing_atom(entry.agent_type), entry, decision)
  end

  defp selection(agent_type, entry, decision) do
    %{
      agent_type: agent_type,
      account: entry && entry.account,
      family: entry && entry.family,
      decision: decision
    }
  end

  defp put_chosen(decision, entry, override \\ nil)

  defp put_chosen(decision, nil, override) do
    Map.merge(decision, %{"agent_type" => to_string(override)})
  end

  defp put_chosen(decision, entry, _override) do
    Map.merge(decision, %{
      "account_id" => entry.account.id,
      "account_slug" => entry.account.slug,
      "provider" => to_string(entry.account.provider),
      "agent_type" => entry.agent_type,
      "family" => entry.family && to_string(entry.family),
      "pool" => entry.pool,
      "model" => entry.model,
      "headroom" => entry |> Map.get(:headroom) |> headroom_value()
    })
  end

  # ---- legacy --------------------------------------------------------------

  defp legacy(task_id, workspace, opts) do
    {provider, fallback} = legacy_resolution(task_id, workspace, opts)
    {provider, fallback, nil}
  end

  defp legacy_resolution(task_id, workspace, opts) do
    case Keyword.get(opts, :override) do
      override when is_atom(override) and not is_nil(override) -> {override, nil}
      _ -> Agents.resolve_revision_provider(task_id, workspace)
    end
  end

  # ---- evaluation ------------------------------------------------------------

  defp context(ws, task, opts) do
    routed = routed_choice(task, ws)

    %{
      ws: ws,
      task: task,
      role: Keyword.get(opts, :role, :main),
      now: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0),
      routed: routed,
      tier: routed.config["model_tier"],
      agent_config: get_in(ws.config || %{}, ["agent", "config"]) || %{},
      security: Keyword.get_lazy(opts, :security, fn -> SecurityPolicy.resolve(ws) end),
      quota_fun: Keyword.get(opts, :quota_fun, &latest_quota/1),
      gemini_code:
        Keyword.get_lazy(opts, :gemini_code, fn -> Arbiter.Quota.provider_code("gemini") end),
      confinement: Keyword.get(opts, :write_confinement, &Agents.write_confinement/2),
      gate: Arbiter.Quota.gate_for_workspace(ws)
    }
  end

  defp routed_choice(%Issue{} = task, ws), do: Routing.choose(task, ws, %{})
  defp routed_choice(_task, ws), do: Routing.default_choice(ws)

  defp candidates(ws) do
    case ProviderSettings.effective(ws, :implementer) do
      %{source: :attached, candidates: candidates} -> candidates
      _ -> []
    end
  end

  defp entry(%{account: account, agent_type: agent_type}, index, ctx) do
    model = predicted_model(account, agent_type, ctx)
    %{family: family, pool: pool} = ModelFamily.classify(account.provider, model)

    %{
      account: account,
      agent_type: agent_type,
      index: index,
      model: model,
      family: family,
      pool: pool
    }
  end

  # The model the spawn would run on this account: the routed config's
  # explicit `"model"` only when the account runs the routed adapter
  # (Dispatch drops it for any other — `apply_agent_type_override/2`),
  # otherwise the tier through the family's own map.
  defp predicted_model(account, agent_type, ctx) do
    routed_model = ctx.routed.config["model"]

    if is_binary(routed_model) and routed_model != "" and
         to_string(ctx.routed.type) == agent_type do
      routed_model
    else
      ModelFamily.model_for_tier(account.provider, ctx.tier, ctx.agent_config)
    end
  end

  defp check(entry, ctx) do
    checks = [
      &check_account/2,
      &check_adapter/2,
      &check_cli/2,
      &check_auth/2,
      &check_circuit/2,
      &check_capacity/2,
      &check_confinement/2,
      &check_quota/2
    ]

    Enum.reduce_while(checks, {:ok, entry}, fn check, {:ok, entry} ->
      case check.(entry, ctx) do
        {:ok, entry} -> {:cont, {:ok, entry}}
        {:drop, reason, detail} -> {:halt, {:drop, drop(entry, reason, detail)}}
      end
    end)
  end

  defp drop(entry, reason, detail), do: Map.merge(entry, %{reason: reason, detail: detail})

  defp check_account(%{account: %ProviderAccount{enabled: false}}, _ctx),
    do: {:drop, "disabled", nil}

  defp check_account(%{account: %ProviderAccount{merged_into_id: into}}, _ctx)
       when not is_nil(into),
       do: {:drop, "merged", "merged into #{into}"}

  defp check_account(entry, _ctx), do: {:ok, entry}

  defp check_adapter(%{agent_type: type} = entry, _ctx) do
    adapter = type && Map.get(Agents.adapters(), String.to_existing_atom(type))

    if adapter,
      do: {:ok, Map.put(entry, :adapter, adapter)},
      else: {:drop, "no_adapter", nil}
  rescue
    ArgumentError -> {:drop, "no_adapter", nil}
  end

  defp check_cli(%{account: %{provider: provider}} = entry, ctx)
       when provider in [:antigravity, :gemini_cli] do
    if Atom.to_string(provider) == ctx.gemini_code,
      do: {:ok, entry},
      else:
        {:drop, "cli_unavailable", "the gemini adapter would run #{ctx.gemini_code || "nothing"}"}
  end

  defp check_cli(entry, _ctx), do: {:ok, entry}

  defp check_auth(%{adapter: adapter} = entry, _ctx) do
    cond do
      AuthHold.open?(adapter) -> {:drop, "auth_expired", "auth hold open"}
      CredentialWatchdog.expired?(adapter) -> {:drop, "auth_expired", "credential expired"}
      true -> {:ok, entry}
    end
  end

  defp check_circuit(%{agent_type: type} = entry, _ctx) do
    if ProviderPool.healthy?(String.to_existing_atom(type)),
      do: {:ok, entry},
      else: {:drop, "circuit_broken", nil}
  end

  defp check_capacity(%{account: account} = entry, ctx) do
    case Concurrency.account_headroom(account, ctx.ws, capacity_opts(ctx)) do
      0 -> {:drop, "at_capacity", "no concurrency slot left (max_concurrent / share)"}
      _ -> {:ok, entry}
    end
  end

  # A follow-up role replaces the task's own workers on the account (see the
  # moduledoc's `at_capacity`); a first dispatch adds to what is running.
  defp capacity_opts(%{role: role, task: %Issue{id: id}}) when role != :main,
    do: [exclude_task: id]

  defp capacity_opts(_ctx), do: []

  defp check_confinement(
         %{adapter: adapter} = entry,
         %{security: %SecurityPolicy{} = policy} = ctx
       ) do
    if policy.permissions.mode == :strict and ctx.confinement.(adapter, policy) == :none,
      do: {:drop, "write_confinement_none", "cannot confine writes under a :strict scope"},
      else: {:ok, entry}
  end

  defp check_confinement(entry, _ctx), do: {:ok, entry}

  defp check_quota(%{account: account, model: model} = entry, ctx) do
    quota = ctx.quota_fun.(account)

    case ctx.gate.check(ctx.task, quota, ctx.ws, account: account, model: model, now: ctx.now) do
      {:hold, reason} ->
        {:drop, "quota_held", Map.get(reason, :phrase)}

      _ ->
        headroom = Headroom.binding(quota, {account, ctx.ws}, model: model, now: ctx.now)
        {:ok, Map.put(entry, :headroom, headroom)}
    end
  end

  defp latest_quota(%ProviderAccount{id: id, provider: provider}),
    do: Arbiter.Quota.latest_for_provider(id, provider)

  defp rank(entries) do
    Enum.sort_by(entries, fn entry ->
      case Map.get(entry, :headroom) do
        %{headroom: h} -> {0, -h, entry.index}
        nil -> {1, 0, entry.index}
      end
    end)
  end

  defp reviewer_family(task_id) do
    Run
    |> Ash.Query.filter(base_task_id == ^task_id and worker_type == :review)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [%Run{provider: provider, model: model}] -> ModelFamily.classify(provider, model).family
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ---- records -----------------------------------------------------------------

  defp candidate_record(entry) do
    headroom = Map.get(entry, :headroom)

    %{
      "account_id" => entry.account.id,
      "account_slug" => entry.account.slug,
      "provider" => to_string(entry.account.provider),
      "agent_type" => entry.agent_type,
      "family" => entry.family && to_string(entry.family),
      "pool" => entry.pool,
      "model" => entry.model,
      "headroom" => headroom_value(headroom),
      "window" => headroom && headroom.window,
      "threshold" => headroom && round4(headroom.threshold),
      "used" => headroom && round4(headroom.used),
      "mode" => headroom && to_string(headroom.mode)
    }
  end

  defp drop_record(entry) do
    %{
      "account_id" => entry.account.id,
      "account_slug" => entry.account.slug,
      "provider" => to_string(entry.account.provider),
      "family" => entry.family && to_string(entry.family),
      "reason" => entry.reason,
      "detail" => entry.detail
    }
  end

  defp headroom_value(%{headroom: h}), do: round4(h)
  defp headroom_value(_), do: nil

  defp round4(n) when is_number(n), do: Float.round(n * 1.0, 4)
  defp round4(_), do: nil

  defp label(%ProviderAccount{provider: provider, slug: slug}), do: "#{provider}:#{slug}"
  defp label(_), do: "(unknown account)"
end
