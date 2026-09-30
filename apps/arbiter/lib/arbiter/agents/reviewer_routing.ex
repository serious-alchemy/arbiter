defmodule Arbiter.Agents.ReviewerRouting do
  @moduledoc """
  Cross-family review (bd-a1ke2c): the ReviewGate reviewer's **model family**
  must differ from the implementer's. A reviewer from the implementer's own
  family shares its blind spots, so Claude-implemented work is reviewed by a
  non-Anthropic family and Gemini-implemented work by a non-Google one.

  ## Opt-in, per workspace

  `review_agent.cross_family: true` turns it on. Unset (or `false`) is today's
  behaviour exactly: `select/3` answers `:off` and the ReviewGate resolves its
  reviewer as it always has.

  ## Families, not CLIs

  Each reviewer candidate is classified by `Arbiter.Agents.ModelFamily` from
  the provider that would run and the model it would run — so an agy reviewer
  configured with a `claude-*` model is Anthropic, and cannot review
  Anthropic-implemented work while another family can.

  The implementer's family is the task's bd-40pzpj pin
  (`Issue.implementer_family`) or, when the task was never routed, the family
  of its latest authoring run (implement / fix pass / conflict resolver). Every
  implementer role shares that one family, so "differs from the implementer" is
  a single comparison. With no implementer family at all there is nothing to
  differ from and the pick is unconstrained.

  ## Candidates and availability

  The workspace's reviewer candidates (`Arbiter.Accounts.ProviderSettings`'s
  `:reviewer` set — attached accounts, else `review_agent.type`), each dropped
  with a reason when it cannot run a pass now:

    * `timed_out` — excluded by the caller: the print-timeout rotation's
      providers that already timed out this round (bd-3hb4ih);
    * `unconfigured` — the entry names no registered adapter;
    * `write_confinement_none` — the scope is `:strict` and the adapter cannot
      confine writes;
    * `disabled` / `merged` — its account is parked or merged away;
    * `auth_expired` — `Arbiter.Agents.AuthHold` is open or
      `Arbiter.Agents.CredentialWatchdog` holds the credential expired;
    * `circuit_broken` — `Arbiter.Agents.ProviderPool.healthy?/1` is false;
    * `quota_held` — the workspace's quota gate would hold it (paced
      included), the same check provider routing makes (bd-40pzpj).

  Survivors are ranked by quota headroom (`Arbiter.Quota.Headroom.binding/3`),
  most first, ties to configured order, candidates with no reading last.

  ## One reviewer family per task

  The first pass pins the chosen family on the task (`Issue.reviewer_family`).
  Every later pass — every round, a post-approval re-review, a print-timeout
  rotation — reviews in that family while it has an available candidate. When
  it has none the pass is **re-picked** among the other eligible families and
  the pin moves there.

  ## Same-family fallback — immediate, recorded, never silent

  Only when every other family is unconfigured, `quota_held`, `auth_expired`,
  `circuit_broken` (or cannot run under the scope, or its account is parked)
  does a same-family candidate review, at once, with `same_family_fallback:
  true` and a reason naming each unavailable family and why. It does not move
  the pin. A candidate excluded only because it `timed_out` is *not* a
  fallback trigger: the rotation answers `{:none, record}` instead, and the
  gate escalates as a pool exhaustion. With no candidate available at all the
  pass still runs at once on the workspace's pre-routing reviewer
  (`outcome: "no_candidate"`), recorded the same way.

  ## The reviewer's tier

  The candidate's model is its family's reviewer tier for the task
  (`ModelFamily.reviewer_tier/2` / `reviewer_thinking/2`: a Google reviewer
  runs Gemini's top model at high effort, never a flash tier) unless the
  workspace pins an explicit `review_agent.config.model`.

  ## Exempt

  `worker_review` of human-authored external PRs never reaches the ReviewGate
  (it runs `Arbiter.Reviews.ExternalReview`), so there is no fleet implementer
  to differ from and nothing here applies.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderSettings
  alias Arbiter.Agents
  alias Arbiter.Agents.AuthHold
  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Agents.ProviderConfig
  alias Arbiter.Agents.ProviderPool
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Quota.Headroom
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workers.Run

  @families [:anthropic, :google, :openai, :xai, :local]

  # Drop reasons that may push a pass back into the implementer's own family.
  # `timed_out` is deliberately absent — see the moduledoc.
  @fallback_triggers ~w(unconfigured write_confinement_none disabled merged
                        auth_expired circuit_broken quota_held)

  @type selection :: %{
          provider: atom(),
          agent_type: String.t(),
          family: ModelFamily.family() | nil,
          account_id: String.t() | nil,
          account_slug: String.t() | nil,
          model: String.t() | nil,
          tier: String.t() | nil,
          thinking: String.t() | nil,
          implementer_family: ModelFamily.family() | nil,
          same_family_fallback: boolean(),
          fallback_reason: String.t() | nil,
          outcome: String.t(),
          record: map()
        }

  @doc "Whether `workspace` requires a cross-family reviewer (`review_agent.cross_family: true`)."
  @spec enabled?(Workspace.t() | nil) :: boolean()
  def enabled?(%Workspace{config: config}),
    do: get_in(config || %{}, ["review_agent", "cross_family"]) == true

  def enabled?(_), do: false

  @doc """
  Choose the reviewer for one review pass on `task` (an `Issue` or its id).

  `{:ok, selection}` names the adapter to spawn, the model / tier / thinking it
  runs and the audit fields to record; `{:none, record}` means no candidate may
  run this pass (the rotation has excluded every eligible one, or the scope
  refuses the pre-routing reviewer); `:off` when the workspace has not opted in.

  Options (all optional; the defaults read the live system):

    * `:tier` — the ReviewGate's reviewer tier for this task (before the
      family's reviewer floor);
    * `:exclude` — adapter atoms that may not run this pass (timed out);
    * `:security` — the reviewer's resolved `SecurityPolicy`;
    * `:quota_fun` — `(ProviderAccount.t() | nil -> quota row | nil)`;
    * `:gemini_code` — the quota code of the CLI the `gemini` adapter spawns;
    * `:now`;
    * `:pin` — write the reviewer-family pin (default `true`).
  """
  @spec select(Workspace.t() | nil, Issue.t() | String.t() | nil, keyword()) ::
          {:ok, selection()} | {:none, map()} | :off
  def select(workspace, task, opts \\ [])

  def select(%Workspace{} = ws, task_id, opts) when is_binary(task_id) do
    if enabled?(ws), do: select(ws, load_issue(task_id), opts), else: :off
  end

  def select(%Workspace{} = ws, task, opts) do
    if enabled?(ws), do: do_select(ws, task, opts), else: :off
  end

  def select(_ws, _task, _opts), do: :off

  # ---- selection ------------------------------------------------------------

  defp do_select(ws, task, opts) do
    ctx = context(ws, task, opts)

    {available, dropped} =
      ws
      |> candidates()
      |> Enum.with_index()
      |> Enum.map(fn {candidate, index} -> check(entry(candidate, index, ctx), ctx) end)
      |> Enum.split_with(&match?({:ok, _}, &1))

    available = available |> Enum.map(&elem(&1, 1)) |> rank()
    dropped = Enum.map(dropped, &elem(&1, 1))
    ctx = Map.merge(ctx, %{available: available, dropped: dropped})

    choose(ctx, Enum.filter(available, &eligible?(&1, ctx.implementer)))
  end

  defp choose(ctx, other) do
    pinned = pinned_family(ctx.task, ctx.implementer)

    case {pinned, Enum.find(other, &(family_string(&1.family) == pinned))} do
      {pinned, %{} = entry} when is_binary(pinned) ->
        {:ok, selection(entry, ctx, "pinned", false, nil)}

      _ ->
        pick_other(ctx, other, pinned)
    end
  end

  defp pick_other(ctx, [best | _], pinned) do
    if Keyword.get(ctx.opts, :pin, true), do: pin(ctx.task, best.family)

    {outcome, reason} =
      if pinned,
        do: {"repicked", "pinned reviewer family #{pinned} unavailable; re-picked #{best.family}"},
        else: {"selected", nil}

    {:ok, selection(best, ctx, outcome, false, reason)}
  end

  defp pick_other(ctx, [], _pinned) do
    others_dropped = Enum.filter(ctx.dropped, &eligible?(&1, ctx.implementer))
    blocked = Enum.reject(others_dropped, &(&1.reason in @fallback_triggers))
    same = Enum.reject(ctx.available, &eligible?(&1, ctx.implementer))

    cond do
      blocked != [] ->
        {:none,
         Map.put(
           record(ctx),
           "reason",
           "no eligible reviewer family left for this pass: " <> drop_list(blocked)
         )}

      same != [] ->
        [best | _] = same
        {:ok, selection(best, ctx, "same_family_fallback", true, fallback_reason(ctx, others_dropped))}

      true ->
        no_candidate(ctx)
    end
  end

  # Nothing can review at all: run at once on the workspace's pre-routing
  # reviewer — never wait — and say so.
  defp no_candidate(%{exclude: [_ | _]} = ctx),
    do: {:none, Map.put(record(ctx), "reason", "every reviewer candidate is unavailable")}

  defp no_candidate(ctx) do
    preferred = Agents.reviewer_type(ctx.ws)

    case Agents.strict_eligible_provider(preferred, ctx.security, Agents.reviewer_pool(ctx.ws)) do
      {:ok, type} ->
        entry = entry(%{agent_type: Atom.to_string(type), account: nil}, 0, ctx)
        same? = not eligible?(entry, ctx.implementer) and not is_nil(ctx.implementer)

        reason =
          "no reviewer available (#{drop_list(ctx.dropped)}); dispatching on the " <>
            "pre-routing reviewer #{type}"

        {:ok, selection(entry, ctx, "no_candidate", same?, reason)}

      {:error, :ineligible} ->
        {:none, Map.put(record(ctx), "reason", "no reviewer can run under this scope")}
    end
  end

  defp eligible?(%{family: nil}, _implementer), do: false
  defp eligible?(%{family: family}, implementer), do: family != implementer

  defp pinned_family(%Issue{reviewer_family: pinned}, implementer)
       when is_binary(pinned) and pinned != "" do
    if pinned == family_string(implementer), do: nil, else: pinned
  end

  defp pinned_family(_task, _implementer), do: nil

  defp pin(%Issue{reviewer_family: current} = task, family) do
    value = family_string(family)

    if value && value != current do
      task
      |> Ash.Changeset.for_update(:pin_reviewer, %{reviewer_family: value})
      |> Ash.update()
      |> case do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("ReviewerRouting: could not pin #{task.id}: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp pin(_task, _family), do: :ok

  defp fallback_reason(ctx, []) do
    "no other model family configured in review_agent.type " <>
      "(implementer family: #{ctx.implementer})"
  end

  defp fallback_reason(_ctx, others_dropped) do
    "no other model family available: " <> drop_list(others_dropped)
  end

  defp drop_list([]), do: "no candidates"

  defp drop_list(entries) do
    Enum.map_join(entries, "; ", fn e ->
      detail = if e.detail, do: " — #{e.detail}", else: ""
      "#{e.family || "unknown family"} (#{e.agent_type}: #{e.reason}#{detail})"
    end)
  end

  defp selection(entry, ctx, outcome, same?, reason) do
    %{
      provider: entry.type,
      agent_type: entry.agent_type,
      family: entry.family,
      account_id: entry.account && entry.account.id,
      account_slug: entry.account && entry.account.slug,
      model: entry.model,
      tier: entry.tier,
      thinking: entry.thinking,
      implementer_family: ctx.implementer,
      same_family_fallback: same?,
      fallback_reason: reason,
      outcome: outcome
    }
    |> then(fn sel -> Map.put(sel, :record, selection_record(sel, ctx)) end)
  end

  defp selection_record(sel, ctx) do
    ctx
    |> record()
    |> Map.merge(%{
      "outcome" => sel.outcome,
      "provider" => to_string(sel.provider),
      "family" => family_string(sel.family),
      "model" => sel.model,
      "tier" => sel.tier,
      "same_family_fallback" => sel.same_family_fallback,
      "fallback_reason" => sel.fallback_reason
    })
  end

  defp record(ctx) do
    %{
      "mode" => "cross_family",
      "implementer_family" => family_string(ctx.implementer),
      "pinned_family" => ctx.task && ctx.task.reviewer_family,
      "candidates" => Enum.map(ctx.available, &entry_record/1),
      "dropped" => Enum.map(ctx.dropped, &entry_record/1)
    }
  end

  defp entry_record(entry) do
    %{
      "provider" => entry.agent_type,
      "family" => family_string(entry.family),
      "model" => entry.model,
      "account_slug" => entry.account && entry.account.slug,
      "headroom" => entry |> Map.get(:headroom) |> headroom_value(),
      "reason" => Map.get(entry, :reason),
      "detail" => Map.get(entry, :detail)
    }
  end

  defp headroom_value(%{headroom: h}) when is_number(h), do: Float.round(h * 1.0, 4)
  defp headroom_value(_), do: nil

  # ---- evaluation -------------------------------------------------------------

  defp context(ws, task, opts) do
    %{
      ws: ws,
      task: task,
      opts: opts,
      implementer: implementer_family(task),
      tier: Keyword.get(opts, :tier),
      exclude: Keyword.get(opts, :exclude, []),
      block: reviewer_block(ws),
      now: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0),
      security: Keyword.get_lazy(opts, :security, fn -> SecurityPolicy.resolve(ws) end),
      quota_fun: Keyword.get(opts, :quota_fun, &latest_quota/1),
      gemini_code:
        Keyword.get_lazy(opts, :gemini_code, fn -> Arbiter.Quota.provider_code("gemini") end),
      gate: Arbiter.Quota.gate_for_workspace(ws),
      available: [],
      dropped: []
    }
  end

  defp reviewer_block(%Workspace{config: config}) do
    get_in(config || %{}, ["review_agent", "config"]) ||
      get_in(config || %{}, ["agent", "config"]) || %{}
  end

  defp candidates(ws) do
    ws
    |> ProviderSettings.effective(:reviewer)
    |> Map.get(:candidates, [])
  rescue
    e ->
      Logger.warning("ReviewerRouting: reviewer candidates unreadable: #{Exception.message(e)}")
      []
  end

  defp entry(%{agent_type: agent_type} = candidate, index, ctx) do
    type = adapter_type(agent_type)
    account = Map.get(candidate, :account)
    provider = classify_provider(type, account, ctx.gemini_code)
    config = ProviderConfig.apply_overrides(ctx.block, to_string(agent_type))
    {model, tier, family} = reviewer_model(provider, config, ctx)

    %{
      type: type,
      agent_type: to_string(agent_type),
      account: account,
      index: index,
      model: model,
      tier: tier,
      family: family,
      thinking: ModelFamily.reviewer_thinking(family, present(config["thinking"]))
    }
  end

  # An explicit `model` is the operator's choice and runs verbatim; otherwise
  # the family's reviewer tier through its adapter map.
  defp reviewer_model(provider, config, ctx) do
    case present(config["model"]) do
      model when is_binary(model) ->
        {model, ctx.tier, ModelFamily.classify(provider, model).family}

      nil ->
        base = ModelFamily.model_for_tier(provider, ctx.tier, ctx.block)
        family = ModelFamily.classify(provider, base).family
        tier = ModelFamily.reviewer_tier(family, ctx.tier)

        model =
          if tier == ctx.tier, do: base, else: ModelFamily.model_for_tier(provider, tier, ctx.block)

        {model, tier, ModelFamily.classify(provider, model).family}
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  # The provider `ModelFamily` classifies by: agy when the `gemini` adapter
  # would spawn it (or the account is an agy account), the upstream gemini
  # CLI otherwise.
  defp classify_provider(:gemini, %ProviderAccount{provider: :antigravity}, _code),
    do: "antigravity"

  defp classify_provider(:gemini, _account, "antigravity"), do: "antigravity"
  defp classify_provider(:gemini, _account, _code), do: "gemini"
  defp classify_provider(type, _account, _code) when is_atom(type), do: to_string(type)

  defp adapter_type(agent_type) do
    Enum.find(Map.keys(Agents.adapters()), &(Atom.to_string(&1) == to_string(agent_type)))
  end

  defp check(entry, ctx) do
    [
      &check_excluded/2,
      &check_adapter/2,
      &check_confinement/2,
      &check_account/2,
      &check_auth/2,
      &check_circuit/2,
      &check_quota/2
    ]
    |> Enum.reduce_while({:ok, entry}, fn check, {:ok, entry} ->
      case check.(entry, ctx) do
        {:ok, entry} -> {:cont, {:ok, entry}}
        {:drop, reason, detail} -> {:halt, {:drop, Map.merge(entry, %{reason: reason, detail: detail})}}
      end
    end)
  end

  defp check_excluded(%{type: type} = entry, ctx) do
    if type in ctx.exclude,
      do: {:drop, "timed_out", "hit its own print-timeout this round"},
      else: {:ok, entry}
  end

  defp check_adapter(%{type: nil}, _ctx), do: {:drop, "unconfigured", "no agent adapter"}
  defp check_adapter(entry, _ctx), do: {:ok, Map.put(entry, :adapter, Agents.for_type(entry.type))}

  defp check_confinement(%{type: type} = entry, ctx) do
    case Agents.strict_eligible_provider(type, ctx.security, [], explicit: true) do
      {:ok, _} -> {:ok, entry}
      {:error, :ineligible} -> {:drop, "write_confinement_none", "cannot confine writes under :strict"}
    end
  end

  defp check_account(%{account: %ProviderAccount{enabled: false}}, _ctx),
    do: {:drop, "disabled", nil}

  defp check_account(%{account: %ProviderAccount{merged_into_id: into}}, _ctx)
       when not is_nil(into),
       do: {:drop, "merged", "merged into #{into}"}

  defp check_account(entry, _ctx), do: {:ok, entry}

  defp check_auth(%{adapter: adapter} = entry, _ctx) do
    cond do
      AuthHold.open?(adapter) -> {:drop, "auth_expired", "auth hold open"}
      CredentialWatchdog.expired?(adapter) -> {:drop, "auth_expired", "credential expired"}
      true -> {:ok, entry}
    end
  end

  defp check_circuit(%{type: type} = entry, _ctx) do
    if ProviderPool.healthy?(type), do: {:ok, entry}, else: {:drop, "circuit_broken", nil}
  end

  defp check_quota(%{account: nil} = entry, _ctx), do: {:ok, entry}

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

  defp latest_quota(_), do: nil

  defp rank(entries) do
    Enum.sort_by(entries, fn entry ->
      case Map.get(entry, :headroom) do
        %{headroom: h} -> {0, -h, entry.index}
        _ -> {1, 0, entry.index}
      end
    end)
  end

  # ---- the implementer's family ------------------------------------------------

  @doc """
  The implementer's model family for `task`: its bd-40pzpj pin, else the
  family of its latest authoring run. `nil` when neither says.
  """
  @spec implementer_family(Issue.t() | nil) :: ModelFamily.family() | nil
  def implementer_family(%Issue{implementer_family: pinned} = task) do
    known_family(pinned) || authoring_run_family(task.id)
  end

  def implementer_family(_task), do: nil

  defp authoring_run_family(task_id) do
    Run
    |> Ash.Query.filter(
      (task_id == ^task_id or base_task_id == ^task_id) and
        kind in [:implement, :fix_pass, :conflict] and not is_nil(provider)
    )
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [%Run{} = run] ->
        known_family(run.model_family) || ModelFamily.classify(run.provider, run.model).family

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc "A family atom for a recorded family string, or `nil` — never a new atom."
  @spec known_family(String.t() | atom() | nil) :: ModelFamily.family() | nil
  def known_family(family) when family in @families, do: family

  def known_family(family) when is_binary(family),
    do: Enum.find(@families, &(Atom.to_string(&1) == family))

  def known_family(_), do: nil

  defp family_string(nil), do: nil
  defp family_string(family) when is_atom(family), do: Atom.to_string(family)

  defp load_issue(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{} = task} -> task
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
