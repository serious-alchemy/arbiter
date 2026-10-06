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

    * `provider_constraint` — the ticket's own provider constraint
      (`Arbiter.Agents.ProviderConstraint`, bd-13pqcp) does not allow the
      account's provider; the detail is the constraint (`exclude gemini`);
    * `disabled` / `merged` — the account is parked or merged away;
    * `no_adapter` — its provider has no agent adapter;
    * `cli_unavailable` — an `antigravity` account on a host where the
      `gemini` adapter would not spawn agy;
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
    * `capability_missing` — `routing.capability_gates` is on and the candidate's
      provider/model lacks a capability the role or the repo requires
      (`Arbiter.Agents.CapabilityMatrix`, bd-57uzkl); checked ahead of quota, so
      a candidate that cannot do the work never has its quota weighed;
    * `below_floor` — a floor is configured (`routing.floors`, bd-c675ny,
      `Arbiter.Agents.Floors`) and the model the candidate would run is on a
      known tier below the repo's blast-radius floor, or — with
      `routing.floors.policy_floor` — below the tier the routing policy
      chose; checked ahead of quota, like `capability_missing`;
    * `paused` — the account or its provider is paused (`Arbiter.Providers.Pause`,
      `arb provider pause`), with the operator's reason as the detail;
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

  ## One "who can take this?" for every surface

  `availability/3` is the single candidate/availability computation. `select/4`
  (dispatch) is built on it, and so are the board's Autopilot hold and slot
  arithmetic (bd-3fvue3): `Arbiter.Board.Snapshot.quota_hold/2` holds a
  most-quota workspace only when no candidate is available, and
  `effective_max_concurrent/3` sums the available candidates' account headroom.
  The per-card hold display (bd-1qjv3j) reads the same function (per ticket, so
  its model tier and pin apply) instead of re-deriving the drop reasons.

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
  alias Arbiter.Agents.CapabilityMatrix
  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Agents.Floors
  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Agents.ProviderConstraint
  alias Arbiter.Agents.ProviderPool
  alias Arbiter.Agents.ReviewerRouting
  alias Arbiter.Agents.Routing
  alias Arbiter.Agents.Routing.Competence
  alias Arbiter.Agents.Routing.Score
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Headroom
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workers.Run

  @selections ~w(failover most_quota scored)
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

  @doc """
  Whether `workspace` routes its implementer by quota: `most_quota`, or
  `scored` (which routes the same way — see `scored?/1`).
  """
  @spec enabled?(Workspace.t() | nil) :: boolean()
  def enabled?(%Workspace{config: config}),
    do: get_in(config || %{}, ["routing", "provider_selection"]) in ["most_quota", "scored"]

  def enabled?(_), do: false

  @doc """
  Whether `workspace` runs `routing.provider_selection: scored` (bd-adtnto, R5).
  `routing.scoring.mode` then picks `shadow` (the default: `most_quota`
  dispatches and the scorer's choice is only recorded) or `enforce` (the
  scorer's order dispatches).
  """
  @spec scored?(Workspace.t() | nil) :: boolean()
  def scored?(%Workspace{config: config}),
    do: get_in(config || %{}, ["routing", "provider_selection"]) == "scored"

  def scored?(_), do: false

  @doc """
  Evaluate every implementer candidate for `task`: the ranked available ones
  (`"candidates"`) and the dropped ones with their reasons (`"dropped"`).

  Options (all optional; the defaults read the live system):

    * `:security` — the dispatch's resolved `SecurityPolicy` (default: the
      workspace's);
    * `:now`;
    * `:quota_fun` — `(ProviderAccount.t() -> quota row | nil)`;
    * `:gemini_code` — the quota code of the CLI the `gemini` adapter would
      spawn (`"antigravity"` for agy, `nil` otherwise);
    * `:write_confinement` — `(adapter, policy -> atom)`;
    * `:role` — the role being routed (default `:main`; `select/4` sets it),
      which decides whether the task's own live workers count toward
      `at_capacity`;
    * `:repo` — the repo this dispatch runs in (default: the task's), whose
      `routing.repos.<repo>.requires` the capability gate reads.
  """
  @spec evaluate(Workspace.t(), Issue.t() | nil, keyword()) :: decision()
  def evaluate(%Workspace{} = ws, task, opts \\ []) do
    ws |> availability(task, opts) |> Map.fetch!(:record)
  end

  @doc """
  "Who can take this?" — the one candidate/availability computation, shared by
  every surface that asks it (bd-3fvue3): `select/4` at dispatch, the board's
  Autopilot hold and slot arithmetic (`Arbiter.Board.Snapshot.quota_hold/2`,
  `effective_max_concurrent/3`) and the per-card hold display (bd-1qjv3j).
  None of them re-derives the candidate set or the drop reasons.

  Takes `evaluate/3`'s options. `task` may be `nil` for a board-wide question
  that is not about one ticket (the model tier is then the workspace default).

    * `:record` — the decision map `evaluate/3` returns;
    * `:available` — the ranked available entries, best first; each carries its
      `:account`, `:agent_type`, `:model`, `:family`, `:headroom` (quota) and
      `:capacity` (`Concurrency.account_headroom/3`: a positive integer, or
      `:unlimited`);
    * `:dropped` — the dropped entries, each with a `:reason` and `:detail`;
    * `:capacity` — how many more workers the available candidates can take
      between them: the sum of their `:capacity`, `:unlimited` when any of them
      is unbounded, `0` with none available.
  """
  @spec availability(Workspace.t(), Issue.t() | nil, keyword()) :: %{
          record: decision(),
          available: [map()],
          dropped: [map()],
          capacity: non_neg_integer() | :unlimited
        }
  def availability(%Workspace{} = ws, task, opts \\ []) do
    {record, available, dropped} = run_evaluation(ws, task, opts)
    %{record: record, available: available, dropped: dropped, capacity: total_capacity(available)}
  end

  # bd-13pqcp: a constrained ticket's record names its constraint.
  defp put_constraint(record, task) do
    case ProviderConstraint.describe(task) do
      nil -> record
      constraint -> Map.put(record, "constraint", constraint)
    end
  end

  defp total_capacity(available) do
    Enum.reduce_while(available, 0, fn
      %{capacity: :unlimited}, _sum -> {:halt, :unlimited}
      %{capacity: n}, sum -> {:cont, sum + n}
    end)
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

    {available, scoring_fields} = available |> Enum.map(&elem(&1, 1)) |> order(ctx)
    dropped = Enum.map(dropped, &elem(&1, 1))

    record =
      %{
        "mode" => if(ctx.scoring, do: "scored", else: "most_quota"),
        "candidates" => Enum.map(available, &candidate_record/1),
        "dropped" => Enum.map(dropped, &drop_record/1),
        "evaluated_at" => DateTime.to_iso8601(ctx.now),
        "model_tier" => ctx.tier
      }
      |> Map.merge(scoring_fields)
      |> put_constraint(task)

    {record, available, dropped}
  end

  @doc """
  Choose the implementer account for `task` in `role` (`:main`, `:resume`,
  `:fix_pass`, …). `{:ok, selection}` names the adapter type to spawn and the
  decision to record; `{:legacy, decision}` means no candidate is available
  and the caller keeps its pre-routing resolution.

  Options: those of `evaluate/3`, plus `:override` (an explicit adapter
  type), `:reviewer_family` (default: the task's cross-family reviewer pin
  (bd-a1ke2c), else its latest review run's) and
  `:pin` (default `true`).
  """
  @spec select(Workspace.t(), Issue.t(), role(), keyword()) ::
          {:ok, selection()} | {:legacy, decision()}
  def select(%Workspace{} = ws, %Issue{} = task, role, opts \\ []) do
    {record, entries, dropped} = run_evaluation(ws, task, Keyword.put(opts, :role, role))
    base = Map.put(record, "role", to_string(role))

    result =
      case Keyword.get(opts, :override) do
        override when is_atom(override) and not is_nil(override) ->
          override(base, entries, ws, override)

        _ ->
          choose(base, entries, dropped, task, opts)
      end

    finish_shadow(result)
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
          {provider, fallback} = legacy_resolution(task, workspace, opts)
          {provider, fallback, Map.put(decision, "agent_type", to_string(provider))}
      end
    else
      legacy(task, workspace, opts)
    end
  rescue
    e ->
      Logger.warning("ProviderRouting: routing #{task.id} crashed: #{Exception.message(e)}")
      legacy(task, workspace, opts)
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
    reviewer = Keyword.get_lazy(opts, :reviewer_family, fn -> reviewer_family(task) end)
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
    |> put_pace_exempt_record(entry)
  end

  # Present only when the P0 exemption decided the dispatch (design §4.2) — a
  # decision with the layer off is byte-identical to what it was.
  defp put_pace_exempt_record(decision, %{pace_exempt: %{} = exemption}) do
    Map.put(decision, "pace_exempt", %{
      "window" => exemption.window,
      "used" => round4(exemption.used),
      "paced" => round4(exemption.paced),
      "cap" => round4(exemption.cap)
    })
  end

  defp put_pace_exempt_record(decision, _entry), do: decision

  @doc """
  Refuse to start a pass on a paused provider/account (bd-5ef587). The legacy
  resolvers hand back the paused original when nothing else is available, so
  every direct `Worker.start` caller checks the resolved provider here.
  """
  @spec ensure_unpaused(atom(), String.t() | nil) ::
          :ok | {:error, {:provider_paused, atom(), String.t()}}
  def ensure_unpaused(provider, ws_id) do
    case Arbiter.Providers.Pause.blocking(provider, ws_id) do
      nil ->
        :ok

      pause ->
        {:error,
         {:provider_paused, provider,
          "held — #{provider} paused: #{pause.reason || "no reason given"}"}}
    end
  end

  # ---- legacy --------------------------------------------------------------

  defp legacy(task, workspace, opts) do
    {provider, fallback} = legacy_resolution(task, workspace, opts)
    {provider, fallback, nil}
  end

  # The pre-routing resolution. bd-13pqcp: it honours the ticket's provider
  # constraint too, so the no-candidate / routing-off paths cannot hand back an
  # excluded provider while a constrained one is available. A caller's explicit
  # `:override` is returned as given — the spawn site's
  # `ProviderConstraint.check/2` is what refuses it if it violates.
  defp legacy_resolution(task, workspace, opts) do
    case Keyword.get(opts, :override) do
      override when is_atom(override) and not is_nil(override) ->
        {override, nil}

      _ ->
        Agents.resolve_revision_provider(task_id_of(task), workspace, constraint_of(task))
    end
  end

  defp task_id_of(%Issue{id: id}), do: id
  defp task_id_of(id) when is_binary(id), do: id

  defp constraint_of(%Issue{} = task), do: ProviderConstraint.from(task)

  defp constraint_of(id) when is_binary(id) do
    case Ash.get(Issue, id) do
      {:ok, %Issue{} = task} -> ProviderConstraint.from(task)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ---- evaluation ------------------------------------------------------------

  defp context(ws, task, opts) do
    routed = routed_choice(task, ws, opts)

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
      capability: capability_gate(ws, task, opts),
      scoring: scoring_config(ws, task, opts),
      floor: Floors.gate(ws, repo_opt(opts) || task_repo(task)),
      gate: Arbiter.Quota.gate_for_workspace(ws)
    }
  end

  # bd-adtnto: `nil` (anything but `provider_selection: scored`) is the whole
  # off path — no window list, no score, no extra record key.
  defp scoring_config(ws, task, opts) do
    if scored?(ws) do
      config = Score.config(ws)

      estimate_fun =
        case Keyword.fetch(opts, :estimate_fun) do
          {:ok, fun} -> fun
          :error -> default_estimate_fun(ws, task, opts)
        end

      %{
        mode: config.mode,
        weight: Score.weight(config, task),
        estimate_fun: estimate_fun
      }
    end
  end

  defp default_estimate_fun(ws, task, opts) do
    if competence?(ws) do
      fn entry -> Competence.estimate(ws, entry, task, opts) end
    else
      nil
    end
  end

  defp competence?(%Workspace{config: config}) do
    get_in(config || %{}, ["routing", "scoring", "competence"]) == true
  end

  # bd-57uzkl: `nil` (the default) is the whole off path — no check runs.
  defp capability_gate(ws, task, opts) do
    repo = repo_opt(opts) || task_repo(task)
    CapabilityMatrix.gate(ws, Keyword.get(opts, :role, :main), repo)
  end

  defp repo_opt(opts) do
    case Keyword.get(opts, :repo) do
      repo when is_binary(repo) and repo != "" -> repo
      _ -> nil
    end
  end

  defp task_repo(%Issue{repo: repo}), do: repo
  defp task_repo(_task), do: nil

  defp routed_choice(%Issue{} = task, ws, opts), do: Routing.decide(task, ws, opts)
  defp routed_choice(_task, ws, _opts), do: Routing.default_choice(ws)

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
      &check_constraint/2,
      &check_account/2,
      &check_adapter/2,
      &check_cli/2,
      &check_auth/2,
      &check_circuit/2,
      &check_capacity/2,
      &check_confinement/2,
      &check_capability/2,
      &check_floor/2,
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

  # bd-13pqcp: the ticket's own provider constraint — first, so the drop names
  # it rather than whatever else would have dropped the account.
  defp check_constraint(%{account: %ProviderAccount{provider: provider}} = entry, ctx) do
    if ProviderConstraint.allows?(ctx.task, provider),
      do: {:ok, entry},
      else: {:drop, "provider_constraint", ProviderConstraint.describe(ctx.task)}
  end

  defp check_constraint(%{agent_type: type} = entry, ctx) do
    if ProviderConstraint.allows?(ctx.task, type),
      do: {:ok, entry},
      else: {:drop, "provider_constraint", ProviderConstraint.describe(ctx.task)}
  end

  defp check_account(%{account: %ProviderAccount{enabled: false}}, _ctx),
    do: {:drop, "disabled", nil}

  defp check_account(%{account: %ProviderAccount{merged_into_id: into}}, _ctx)
       when not is_nil(into),
       do: {:drop, "merged", "merged into #{into}"}

  defp check_account(%{account: %ProviderAccount{} = account} = entry, _ctx) do
    case Arbiter.Providers.Pause.for_account(account) do
      nil -> {:ok, entry}
      pause -> {:drop, "paused", pause.reason || "paused by #{pause.by || "the operator"}"}
    end
  end

  defp check_account(%{account: nil, agent_type: type} = entry, _ctx) do
    case Arbiter.Providers.Pause.for_provider(type) do
      nil -> {:ok, entry}
      pause -> {:drop, "paused", pause.reason}
    end
  end

  defp check_account(entry, _ctx), do: {:ok, entry}

  defp check_adapter(%{agent_type: type} = entry, _ctx) do
    adapter = type && Map.get(Agents.adapters(), String.to_existing_atom(type))

    if adapter,
      do: {:ok, Map.put(entry, :adapter, adapter)},
      else: {:drop, "no_adapter", nil}
  rescue
    ArgumentError -> {:drop, "no_adapter", nil}
  end

  defp check_cli(%{account: %{provider: :antigravity}} = entry, ctx) do
    if ctx.gemini_code == "antigravity",
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
      capacity -> {:ok, Map.put(entry, :capacity, capacity)}
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

  # bd-57uzkl: a hard gate after availability and before quota (design §6.1).
  defp check_capability(entry, %{capability: nil}), do: {:ok, entry}

  defp check_capability(%{account: account, model: model} = entry, %{capability: gate} = ctx) do
    provider = CapabilityMatrix.provider_code(account.provider, ctx.gemini_code)

    case CapabilityMatrix.check(gate.rows, gate.requires, provider, model) do
      :ok -> {:ok, entry}
      {:missing, _capability, detail} -> {:drop, "capability_missing", detail}
    end
  end

  # bd-c675ny (design §6.4): the floors are a hard gate after capability and
  # before quota. `nil` (no `routing.floors` config, the default) is the whole
  # off path. A model on no known tier is not below any floor.
  defp check_floor(entry, %{floor: nil}), do: {:ok, entry}

  defp check_floor(%{account: account, model: model} = entry, %{floor: gate} = ctx) do
    case Floors.check(gate, ctx.routed, account.provider, model, ctx.agent_config) do
      :ok -> {:ok, entry}
      {:below, detail} -> {:drop, "below_floor", detail}
    end
  end

  defp check_quota(%{account: account, model: model} = entry, ctx) do
    quota = ctx.quota_fun.(account)

    case ctx.gate.check(ctx.task, quota, ctx.ws, account: account, model: model, now: ctx.now) do
      {:hold, reason} ->
        {:drop, "quota_held", Map.get(reason, :phrase)}

      _ ->
        # The P0 pace exemption (bd-6bxv7h) reads the task's own priority: an
        # exempt dispatch's headroom is against the lifted line, the same one
        # the gate just allowed it through, and a dispatch that only got
        # through on the exemption says so on its candidate.
        priority = task_priority(ctx.task)
        headroom_opts = [model: model, now: ctx.now, priority: priority]
        entry = put_pace_exempt(entry, quota, account, ctx, headroom_opts)

        if ctx.scoring do
          windows = Headroom.windows(quota, {account, ctx.ws}, headroom_opts)
          headroom = Enum.min_by(windows, & &1.headroom, fn -> nil end)
          {:ok, entry |> Map.put(:headroom, headroom) |> Map.put(:windows, windows)}
        else
          headroom = Headroom.binding(quota, {account, ctx.ws}, headroom_opts)
          {:ok, Map.put(entry, :headroom, headroom)}
        end
    end
  end

  defp task_priority(%{priority: priority}) when is_integer(priority), do: priority
  defp task_priority(_task), do: nil

  defp put_pace_exempt(entry, quota, account, ctx, opts) do
    case Gate.pace_exemption(quota, {account, ctx.ws}, opts) do
      nil -> entry
      exemption -> Map.put(entry, :pace_exempt, exemption)
    end
  end

  defp latest_quota(%ProviderAccount{id: id, provider: provider}),
    do: Arbiter.Quota.latest_for_provider(id, provider)

  # The survivors, best first, plus the scoring fields for the record.
  #
  # Off (`most_quota`): by headroom. `scored` in `enforce`: by the scorer's J.
  # `scored` in `shadow`: still by headroom — dispatch is unchanged — with the
  # scorer's ranking recorded beside it (design §9.2 item 3).
  defp order(entries, %{scoring: nil}), do: {rank(entries), %{}}

  defp order(entries, %{scoring: scoring}) do
    estimated = Enum.map(entries, &estimate(&1, scoring))
    scored = Score.rank(estimated, weight: scoring.weight)
    base = %{"scoring_mode" => to_string(scoring.mode), "time_weight" => scoring.weight}

    case scoring.mode do
      :enforce ->
        {scored, base}

      :shadow ->
        scores = Map.new(scored, &{&1.index, &1.score})
        headroom_order = estimated |> rank() |> Enum.map(&annotate(&1, scores))

        {headroom_order,
         Map.put(base, "shadow", %{"ranking" => Enum.map(scored, &ranking_row/1)})}
    end
  end

  defp annotate(entry, scores), do: Map.put(entry, :score, Map.fetch!(scores, entry.index))

  # R6's competence matrix plugs in here: `(entry -> %{draw:, time_h:} | nil)`.
  defp estimate(entry, %{estimate_fun: nil}), do: entry

  defp estimate(entry, %{estimate_fun: fun}) do
    case fun.(entry) do
      %{} = estimate ->
        Map.merge(entry, Map.take(estimate, [:draw, :time_h, :sides, :reviewer_windows, :cell]))

      _ ->
        entry
    end
  end

  defp rank(entries) do
    Enum.sort_by(entries, fn entry ->
      case Map.get(entry, :headroom) do
        %{headroom: h} -> {0, -h, entry.index}
        nil -> {1, 0, entry.index}
      end
    end)
  end

  # bd-a1ke2c: the task's cross-family reviewer pin, when it has one, is the
  # family every later review pass uses; otherwise the latest review run's.
  defp reviewer_family(%Issue{reviewer_family: pinned, id: task_id}) do
    ReviewerRouting.known_family(pinned) || latest_reviewer_family(task_id)
  end

  defp latest_reviewer_family(task_id) do
    Run
    |> Ash.Query.filter(base_task_id == ^task_id and kind == :review)
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
    |> Map.merge(score_fields(Map.get(entry, :score)))
    |> maybe_put_cell(entry)
  end

  defp score_fields(nil), do: %{}

  defp score_fields(%{} = score) do
    base = %{
      "price" => finite4(score.price),
      "draw" => round4(score.draw),
      "time_h" => round4(score.time_h),
      "score" => finite4(score.score),
      "over_line" => score.over_line?
    }

    base =
      if Map.get(score, :reviewer_unpriced?),
        do: Map.put(base, "reviewer_unpriced", true),
        else: base

    if score.sides do
      runs =
        %{
          "author" => round4(Map.get(score.sides, :author))
        }
        |> then(fn m ->
          case Map.get(score.sides, :review) do
            rev when is_number(rev) -> Map.put(m, "review", round4(rev))
            _ -> m
          end
        end)

      Map.put(base, "expected_runs", runs)
    else
      base
    end
  end

  defp maybe_put_cell(record, %{cell: %{} = cell}), do: Map.put(record, "cell", cell)
  defp maybe_put_cell(record, _), do: record

  defp ranking_row(entry) do
    %{
      "account_id" => entry.account.id,
      "account_slug" => entry.account.slug,
      "family" => entry.family && to_string(entry.family),
      "model" => entry.model,
      "price" => finite4(entry.score.price),
      "time_term" => round4(entry.score.time_term),
      "score" => finite4(entry.score.score)
    }
  end

  # ---- shadow ------------------------------------------------------------------

  # Once the real pick is known, say what the scorer would have picked in its
  # place and whether they agree. Only a fresh choice (`selected`, `fallback`)
  # is comparable: a pin, an override or no candidate never consulted the rank.
  defp finish_shadow({:ok, %{decision: decision} = selection}),
    do: {:ok, %{selection | decision: shadow_outcome(decision)}}

  defp finish_shadow({:legacy, decision}), do: {:legacy, shadow_outcome(decision)}

  defp shadow_outcome(%{"shadow" => %{"ranking" => ranking} = shadow} = decision) do
    comparable = decision["outcome"] in ["selected", "fallback"]
    pick = if comparable, do: shadow_pick(ranking, decision["excluded_family"])
    actual = if comparable, do: Enum.find(ranking, &same_pick?(&1, decision))

    fields =
      cond do
        is_nil(pick) or is_nil(actual) ->
          %{"comparable" => false, "pick" => nil, "agrees" => nil}

        same_pick?(pick, decision) ->
          %{"comparable" => true, "pick" => pick, "agrees" => true}

        true ->
          %{
            "comparable" => true,
            "pick" => pick,
            "agrees" => false,
            "reason" => disagreement_reason(pick, actual)
          }
      end

    Map.put(decision, "shadow", Map.merge(shadow, fields))
  end

  defp shadow_outcome(decision), do: decision

  # The fallback path's own rule: leave the reviewer's family out unless that
  # would leave nothing.
  defp shadow_pick(ranking, excluded) do
    others = Enum.reject(ranking, &(excluded && &1["family"] == excluded))
    List.first(if others == [], do: ranking, else: others)
  end

  defp same_pick?(row, decision),
    do: row["account_id"] == decision["account_id"] and row["model"] == decision["model"]

  defp disagreement_reason(pick, actual) do
    cond do
      pick["time_term"] < actual["time_term"] and pick["price"] >= actual["price"] ->
        "time term: scored pick merges sooner (#{pick["time_term"]} vs #{actual["time_term"]})"

      pick["price"] < actual["price"] ->
        "price: scored pick is cheaper (#{pick["price"]} vs #{actual["price"]})"

      true ->
        "tiebreak"
    end
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

  defp finite4(n) when is_number(n), do: round4(n)
  defp finite4(_), do: nil

  defp round4(n) when is_number(n), do: Float.round(n * 1.0, 4)
  defp round4(_), do: nil

  defp label(%ProviderAccount{provider: provider, slug: slug}), do: "#{provider}:#{slug}"
  defp label(_), do: "(unknown account)"
end
