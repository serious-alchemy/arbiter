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
    * `paused` — the account or its provider is paused (`Arbiter.Providers.Pause`,
      `arb provider pause`); a fallback trigger like `quota_held`;
    * `capability_missing` — `routing.capability_gates` is on and the candidate's
      provider/model lacks a capability the task's repo requires
      (`Arbiter.Agents.CapabilityMatrix`, bd-57uzkl); checked ahead of quota and
      a fallback trigger like `quota_held`;
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
  alias Arbiter.Agents.CapabilityMatrix
  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Agents.ProviderConfig
  alias Arbiter.Agents.ProviderPool
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Guardrails
  alias Arbiter.Guardrails.Eligibility
  alias Arbiter.Guardrails.Profile
  alias Arbiter.Guardrails.Rules
  alias Arbiter.Quota.Headroom
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Sandbox
  alias Arbiter.Workers.Run

  @families [:anthropic, :google, :openai, :xai, :local]

  # Drop reasons that may push a pass back into the implementer's own family.
  # `timed_out` is deliberately absent — see the moduledoc.
  @fallback_triggers ~w(unconfigured write_confinement_none disabled merged
                        auth_expired circuit_broken quota_held paused capability_missing
                        sandbox_backend guardrail_ineligible egress_unenforceable)

  @tier_ladder ~w(economy standard premium)

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
    if enabled?(ws) or Guardrails.guarded?(),
      do: select(ws, load_issue(task_id), opts),
      else: :off
  end

  def select(%Workspace{} = ws, task, opts) do
    if enabled?(ws) or required?(ws, task, opts), do: do_select(ws, task, opts), else: :off
  end

  def select(_ws, _task, _opts), do: :off

  @doc """
  Whether cross-family review applies to `task` in `workspace`: the workspace
  opted in (`enabled?/1`), **or** the implementer's guardrail profile requires it
  (`review.cross_family: :required`, design §3.3 — a low tier forces the rule
  even where `review_agent.cross_family` is off). The ReviewGate asks this, not
  `enabled?/1`, whether to route a pass through `select/3`.
  """
  @spec applies?(Workspace.t() | nil, Issue.t() | String.t() | nil) :: boolean()
  def applies?(%Workspace{} = ws, task) do
    enabled?(ws) or required?(ws, task_of(task), [])
  end

  def applies?(_ws, _task), do: false

  @doc """
  The model a reviewer pass on `agent_type` would run in `workspace` — the same
  read `select/3` makes for a candidate (the workspace's reviewer config, else
  the family's reviewer tier for `:tier`). The guardrail gate needs it for a
  reviewer that was named rather than selected: a `nil` model would match only
  the provider-level rule. `nil` when it cannot be worked out.
  """
  @spec predicted_model(Workspace.t(), atom() | String.t(), keyword()) :: String.t() | nil
  def predicted_model(%Workspace{} = ws, agent_type, opts \\ []) do
    opts = opts |> Keyword.take([:tier, :gemini_code]) |> Keyword.put(:guardrail_rules, [])
    ctx = context(ws, nil, opts)
    entry(%{agent_type: to_string(agent_type), account: nil}, 0, ctx).model
  rescue
    _ -> nil
  end

  defp task_of(task_id) when is_binary(task_id), do: load_issue(task_id)
  defp task_of(task), do: task

  defp required?(ws, %Issue{} = task, opts) do
    case guardrail_gate(ws, task, opts) do
      %{implementer: %Profile{review: %{cross_family: :required}}} -> true
      _ -> false
    end
  end

  defp required?(_ws, _task, _opts), do: false

  @doc """
  The reviewer `ReviewerRouting` would pick for `implementer_family`, without
  writing a pin (`pin: false`). Used by `ProviderRouting` and `Routing.Score` to
  price review runs on the projected reviewer's pool (design §3.4).
  """
  @spec project(Workspace.t() | nil, ModelFamily.family() | nil, keyword()) ::
          {:ok, selection()} | {:none, map()} | :off
  def project(ws, implementer_family, opts \\ [])

  def project(%Workspace{} = ws, implementer_family, opts) do
    task = Keyword.get(opts, :task)

    opts =
      opts
      |> Keyword.put(:pin, false)
      |> Keyword.put(:implementer_family, implementer_family)

    select(ws, task, opts)
  end

  def project(_ws, _implementer_family, _opts), do: :off

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

    stale = ctx.task && stale_pin(ctx.task, ctx.implementer)

    {outcome, reason} =
      cond do
        pinned ->
          {"repicked", "pinned reviewer family #{pinned} unavailable; re-picked #{best.family}"}

        stale ->
          {"repicked",
           "implementer family is now #{ctx.implementer}; pinned reviewer family #{stale} " <>
             "no longer differs from it; re-picked #{best.family}"}

        true ->
          {"selected", nil}
      end

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

      same != [] and same_family_hold?(ctx) ->
        hold(
          ctx,
          "no other model family is eligible, and the implementer's guardrail profile does " <>
            "not allow a same-family review: " <> drop_list(others_dropped)
        )

      same != [] ->
        [best | _] = same

        {:ok,
         selection(best, ctx, "same_family_fallback", true, fallback_reason(ctx, others_dropped))}

      true ->
        no_candidate(ctx)
    end
  end

  # The implementer's profile says a same-family review waits (`review.
  # same_family_fallback: :hold`, the quarantine default). `:record` and
  # `:workspace` keep bd-a1ke2c's recorded fallback.
  defp same_family_hold?(ctx), do: review_knob(ctx.guardrails, :same_family_fallback) == :hold

  # A guardrail hold: no reviewer is started for this pass. The `"guardrail_hold"`
  # key is what tells the ReviewGate to wait rather than fall through to its
  # ordinary reviewer resolution (which knows nothing of tiers).
  defp hold(ctx, reason) do
    {:none, ctx |> record() |> Map.merge(%{"reason" => reason, "guardrail_hold" => reason})}
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

        # bd-57uzkl (E17): the pre-routing reviewer meets the same hard gate,
        # or the gate is only advisory.
        # G13: and the same guardrail gate — the pre-routing reviewer is a
        # subject like any other, and "nothing else is available" must not mean
        # "so run the one the tiers rule out".
        with {:ok, entry} <- check_capability(entry, ctx),
             {:ok, entry} <- check_guardrails(entry, ctx) do
          same? = not eligible?(entry, ctx.implementer) and not is_nil(ctx.implementer)

          reason =
            "no reviewer available (#{drop_list(ctx.dropped)}); dispatching on the " <>
              "pre-routing reviewer #{type}"

          if same? and same_family_hold?(ctx) do
            hold(
              ctx,
              "no reviewer from another family is available, and the implementer's guardrail " <>
                "profile does not allow a same-family review: " <> drop_list(ctx.dropped)
            )
          else
            {:ok, selection(entry, ctx, "no_candidate", same?, reason)}
          end
        else
          {:drop, "guardrail_ineligible", detail} ->
            hold(
              ctx,
              "no reviewer is eligible under the guardrails (the pre-routing reviewer #{type}: " <>
                "#{detail}; others: #{drop_list(ctx.dropped)})"
            )

          {:drop, reason, detail} ->
            {:none,
             Map.put(
               record(ctx),
               "reason",
               "the pre-routing reviewer #{type} cannot take this pass: #{reason} (#{detail})"
             )}
        end

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

  # The recorded pin when the implementer has moved into that family.
  defp stale_pin(%Issue{reviewer_family: pinned}, implementer)
       when is_binary(pinned) and pinned != "" do
    if pinned == family_string(implementer), do: pinned
  end

  defp stale_pin(_task, _implementer), do: nil

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
      "authoring_families" => ctx.authoring,
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
    guardrails = guardrail_gate(ws, task, opts)

    %{
      ws: ws,
      task: task,
      opts: opts,
      implementer: Keyword.get(opts, :implementer_family) || implementer_family(task),
      authoring: authoring_record(task),
      guardrails: guardrails,
      tier: bump_tier(Keyword.get(opts, :tier), review_knob(guardrails, :min_reviewer_tier)),
      confinement: Keyword.get(opts, :write_confinement, &Agents.write_confinement/2),
      egress_confinement: Keyword.get(opts, :egress_confinement, &Agents.egress_confinement/2),
      exclude: Keyword.get(opts, :exclude, []),
      block: reviewer_block(ws),
      now: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0),
      security: Keyword.get_lazy(opts, :security, fn -> SecurityPolicy.resolve(ws) end),
      quota_fun: Keyword.get(opts, :quota_fun, &latest_quota/1),
      gemini_code:
        Keyword.get_lazy(opts, :gemini_code, fn -> Arbiter.Quota.provider_code("gemini") end),
      capability: CapabilityMatrix.gate(ws, :reviewer, task_repo(task)),
      gate: Arbiter.Quota.gate_for_workspace(ws),
      available: [],
      dropped: []
    }
  end

  defp task_repo(%Issue{repo: repo}), do: repo
  defp task_repo(_task), do: nil

  # ---- guardrails (G13, bd-atll60) ------------------------------------------------

  # `nil` — no subject rule configured — is the whole off path. Otherwise the
  # ticket's side of the question is read once per selection (its difficulty, its
  # in-force permissions) together with the **implementer's** effective profile,
  # whose `review` knobs (cross-family required, same-family fallback hold, minimum
  # reviewer tier) shape this pass (design §3.3).
  defp guardrail_gate(ws, task, opts) do
    case Keyword.get_lazy(opts, :guardrail_rules, &Rules.all/0) do
      [] ->
        nil

      rules ->
        %{
          rules: rules,
          difficulty: gate_difficulty(task),
          permissions: gate_permissions(task),
          repo: task_repo(task),
          implementer: implementer_profile(ws, task, rules)
        }
    end
  end

  defp gate_difficulty(%Issue{difficulty: difficulty}), do: difficulty
  defp gate_difficulty(_task), do: nil

  defp gate_permissions(%Issue{} = task), do: Arbiter.Tasks.Permissions.in_force(task)
  defp gate_permissions(_task), do: []

  defp implementer_profile(ws, %Issue{} = task, rules) do
    case implementer_subject(task) do
      {provider, model} ->
        Guardrails.effective(Guardrails.subject(provider, model), ws, task.repo, rules: rules)

      nil ->
        nil
    end
  end

  defp implementer_profile(_ws, _task, _rules), do: nil

  # The (provider, model) that wrote the code under review: the latest authoring
  # run, else the account the task is pinned to (bd-40pzpj).
  defp implementer_subject(%Issue{id: id, implementer_account_id: account_id}) do
    run =
      Run
      |> Ash.Query.filter(
        (task_id == ^id or base_task_id == ^id) and kind in [:implement, :fix_pass, :conflict] and
          not is_nil(provider)
      )
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!()
      |> List.first()

    case {run, account_id && Arbiter.Accounts.Resolver.get(account_id)} do
      {%Run{provider: provider, model: model}, _} -> {provider, model}
      {nil, %ProviderAccount{provider: provider}} -> {provider, nil}
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp review_knob(%{implementer: %Profile{review: review}}, key), do: Map.get(review, key)
  defp review_knob(_guardrails, _key), do: nil

  # A profile's `min_reviewer_tier` raises the tier the reviewer runs at; it never
  # lowers one the ReviewGate already asked for.
  defp bump_tier(tier, nil), do: tier

  defp bump_tier(tier, min) do
    min = Atom.to_string(min)
    rank = fn t -> Enum.find_index(@tier_ladder, &(&1 == t)) || -1 end
    if rank.(min) > rank.(tier), do: min, else: tier
  end

  # Oldest-first families that authored on the branch; only recorded when more
  # than one did, so the audit shows a mixed-family branch.
  defp authoring_record(%Issue{id: id}) do
    case id |> authoring_families() |> Enum.reverse() do
      [_, _ | _] = families -> Enum.map(families, &family_string/1)
      _ -> nil
    end
  end

  defp authoring_record(_task), do: nil

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
          if tier == ctx.tier,
            do: base,
            else: ModelFamily.model_for_tier(provider, tier, ctx.block)

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
      &check_guardrails/2,
      &check_guardrail_floor/2,
      &check_confinement/2,
      &check_sandbox_backend/2,
      &check_account/2,
      &check_auth/2,
      &check_circuit/2,
      &check_capability/2,
      &check_quota/2
    ]
    |> Enum.reduce_while({:ok, entry}, fn check, {:ok, entry} ->
      case check.(entry, ctx) do
        {:ok, entry} ->
          {:cont, {:ok, entry}}

        {:drop, reason, detail} ->
          {:halt, {:drop, Map.merge(entry, %{reason: reason, detail: detail})}}
      end
    end)
  end

  defp check_excluded(%{type: type} = entry, ctx) do
    if type in ctx.exclude,
      do: {:drop, "timed_out", "hit its own print-timeout this round"},
      else: {:ok, entry}
  end

  defp check_adapter(%{type: nil}, _ctx), do: {:drop, "unconfigured", "no agent adapter"}

  defp check_adapter(entry, _ctx),
    do: {:ok, Map.put(entry, :adapter, Agents.for_type(entry.type))}

  # G13 (design §5.4): may this reviewer subject review this ticket? A reviewer
  # needs the right to review at the ticket's difficulty, and a data class
  # (`phi_data`) binds it exactly as it binds the implementer. Reviewers get no
  # action permissions. The drop is a same-family-fallback trigger, like
  # `quota_held`: an ineligible other family leaves only the implementer's own.
  defp check_guardrails(entry, %{guardrails: nil}), do: {:ok, entry}

  defp check_guardrails(%{type: type} = entry, %{guardrails: gate} = ctx) do
    attrs = %{
      provider: classify_provider(type, entry.account, ctx.gemini_code),
      model: entry.model,
      role: :reviewer,
      account: entry.account || workspace_account(ctx.ws, type),
      difficulty: gate.difficulty,
      permissions: gate.permissions,
      workspace: ctx.ws,
      repo: gate.repo
    }

    case Eligibility.evaluate(attrs, rules: gate.rules) do
      {:ok, %{profile: profile}} -> {:ok, Map.put(entry, :guardrail, %{profile: profile})}
      {:error, detail} -> {:drop, "guardrail_ineligible", detail}
    end
  end

  defp workspace_account(%Workspace{id: ws_id}, type) when is_atom(type) and not is_nil(type) do
    Arbiter.Accounts.Resolver.account(ws_id, type)
  rescue
    _ -> nil
  end

  defp workspace_account(_ws, _type), do: nil

  # §3.4: the tier's floor, asked of the adapter after the floor is applied to the
  # review spawn's policy — never a weaker posture than the tier states.
  defp check_guardrail_floor(
         %{guardrail: %{profile: %Profile{} = profile}, adapter: adapter} = entry,
         ctx
       ) do
    floored = ctx.security |> SecurityPolicy.for_review_spawn() |> Guardrails.floor(profile)

    case Guardrails.enforceable(adapter, floored, profile,
           write_confinement: ctx.confinement,
           egress_confinement: ctx.egress_confinement
         ) do
      :ok ->
        {:ok, entry}

      {:error, reason} ->
        {:drop, Atom.to_string(reason), Guardrails.unmet_detail(reason, profile, floored)}
    end
  end

  defp check_guardrail_floor(entry, _ctx), do: {:ok, entry}

  defp check_confinement(%{type: type} = entry, ctx) do
    case Agents.strict_eligible_provider(type, ctx.security, [], explicit: true) do
      {:ok, _} ->
        {:ok, entry}

      {:error, :ineligible} ->
        {:drop, "write_confinement_none", "cannot confine writes under :strict"}
    end
  end

  # Reviewers spawn under `sandbox.review_backend`, not `sandbox.backend`.
  defp check_sandbox_backend(%{type: type} = entry, ctx) do
    policy = SecurityPolicy.for_review_spawn(ctx.security)

    case Sandbox.module(policy, type) do
      {:ok, _} ->
        {:ok, entry}

      {:error, {:sandbox_backend_unavailable, backend, _}} ->
        {:drop, "sandbox_backend", "#{type} unsupported by #{backend}"}
    end
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

  # bd-57uzkl: a hard gate before quota (design §6.1). The provider is the one
  # `ModelFamily` classified (agy when the `gemini` adapter would spawn it).
  defp check_capability(entry, %{capability: nil}), do: {:ok, entry}

  defp check_capability(%{type: type, account: account, model: model} = entry, ctx) do
    provider = classify_provider(type, account, ctx.gemini_code)

    case CapabilityMatrix.check(ctx.capability.rows, ctx.capability.requires, provider, model) do
      :ok -> {:ok, entry}
      {:missing, _capability, detail} -> {:drop, "capability_missing", detail}
    end
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
  The implementer's model family for `task`: the family of its latest
  authoring run (implement / fix pass / conflict resolver) — the run actually
  being reviewed — else its bd-40pzpj pin. `nil` when neither says.

  The pin is only a fallback: a task re-dispatched to another provider keeps
  its first-routed pin, so trusting it over the runs reviews the new
  implementer's work against the old implementer's family (bd-avgph4).
  """
  @spec implementer_family(Issue.t() | nil) :: ModelFamily.family() | nil
  def implementer_family(%Issue{implementer_family: pinned} = task) do
    case authoring_families(task.id) do
      [latest | _] -> latest
      [] -> known_family(pinned)
    end
  end

  def implementer_family(_task), do: nil

  # Families of the task's authoring runs, newest first, de-duplicated.
  defp authoring_families(task_id) do
    Run
    |> Ash.Query.filter(
      (task_id == ^task_id or base_task_id == ^task_id) and
        kind in [:implement, :fix_pass, :conflict] and not is_nil(provider)
    )
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.read!()
    |> Enum.map(
      &(known_family(&1.model_family) || ModelFamily.classify(&1.provider, &1.model).family)
    )
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  rescue
    _ -> []
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
