defmodule Arbiter.Agents.ProviderRoutingModelChoiceTest do
  @moduledoc """
  bd-3go56q (R9 of `docs/design/paced-quota-routing-signals.md`, §5.2-§5.3):
  within-provider model choice.

    * a tier may list several models, and `allow_upgrade` reaches tiers above
      the policy's: a candidate is an (account, model) pair, each on its own
      pool, never below the policy's tier;
    * the agy worked example (§5.3): the Gemini pool is over its line, the
      Claude/GPT pool has room, and the router spends the pool that has room;
    * the selection carries `:model` only for a model the tier's default
      resolution would not spawn;
    * the no-regression invariant (§9): one model per tier — every workspace's
      config today — yields today's single entry per account.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Agents.PoolReservations
  alias Arbiter.Agents.ProviderRouting
  alias Arbiter.Quota.{AnthropicQuota, CodexQuota, GoogleQuota}
  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    on_exit(fn -> :ets.delete_all_objects(:arbiter_provider_circuit_breakers) end)
    :ok
  end

  @gemini_flash "gemini-3.8-flash-low"
  @claude_sonnet "claude-sonnet-4-6"
  @agy_gemini_pool "antigravity:gemini_models"
  @agy_claude_gpt_pool "antigravity:claude_and_gpt_models"

  defp config(opts \\ []) do
    routing = %{
      "provider_selection" => Keyword.get(opts, :selection, "most_quota"),
      "policy" => "by_difficulty"
    }

    routing =
      case Keyword.get(opts, :scoring) do
        nil -> routing
        scoring -> Map.put(routing, "scoring", scoring)
      end

    base = %{"routing" => routing}

    case Keyword.get(opts, :agy_tier_models) do
      nil ->
        base

      tiers ->
        Map.put(base, "agent", %{"config" => %{"gemini" => %{"tier_models" => tiers}}})
    end
  end

  defp workspace!(cfg),
    do: Ash.create!(Workspace, %{name: "mc-#{System.unique_integer([:positive])}", config: cfg})

  defp account!(provider, slug) do
    Ash.create!(ProviderAccount, %{
      provider: provider,
      slug: "#{slug}-#{System.unique_integer([:positive])}"
    })
  end

  defp allow!(ws, account, position) do
    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: account.provider,
      provider_account_id: account.id,
      implementer_position: position
    })
  end

  defp task!(ws, attrs),
    do: Ash.create!(Issue, Map.merge(%{title: "pick a model", workspace_id: ws.id}, attrs))

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp ahead(secs), do: DateTime.add(now(), secs, :second)

  defp claude_quota(u5, u7) do
    %AnthropicQuota{
      provider: "claude",
      utilization_5h: u5,
      reset_5h_at: ahead(9_000),
      status_5h: "allowed",
      utilization_7d: u7,
      reset_7d_at: ahead(302_400),
      status_7d: "allowed",
      captured_at: now()
    }
  end

  defp codex_quota(session_pct) do
    %CodexQuota{
      provider: "codex",
      session_used_percent: session_pct,
      session_reset_at: ahead(3_600),
      weekly_used_percent: 0.0,
      weekly_reset_at: ahead(302_400),
      limit_reached: false,
      captured_at: now()
    }
  end

  # `*_used` are percentages of each pool's 5h window; the weekly windows idle.
  defp agy_quota(gemini_used, claude_gpt_used) do
    bucket = fn group, window, used, reset ->
      %{
        "model_id" => "#{group}_#{window}",
        "remaining_percentage" => 100.0 - used,
        "reset_at" => DateTime.to_iso8601(reset)
      }
    end

    %GoogleQuota{
      provider: "antigravity",
      captured_at: now(),
      reset_at: ahead(9_000),
      snapshot: %{
        "models" => [
          bucket.("gemini_models", "5h", gemini_used, ahead(9_000)),
          bucket.("gemini_models", "weekly", 0.0, ahead(302_400)),
          bucket.("claude_and_gpt_models", "5h", claude_gpt_used, ahead(9_000)),
          bucket.("claude_and_gpt_models", "weekly", 0.0, ahead(302_400))
        ]
      }
    }
  end

  defp opts(pairs, extra \\ []) do
    by_id = Map.new(pairs, fn {account, quota} -> {account.id, quota} end)

    Keyword.merge(
      [quota_fun: fn account -> Map.get(by_id, account.id) end, gemini_code: "antigravity"],
      extra
    )
  end

  # A D1 ticket (economy) in a workspace with `claude` first and `agy` second.
  defp agy_and_claude(cfg) do
    ws = workspace!(cfg)
    claude = account!(:claude, "claude")
    agy = account!(:antigravity, "agy")
    allow!(ws, claude, 0)
    allow!(ws, agy, 1)
    %{ws: ws, claude: claude, agy: agy, task: task!(ws, %{difficulty: 1})}
  end

  defp models(entries), do: Enum.map(entries, & &1["model"])
  defp dropped_reasons(decision), do: Enum.map(decision["dropped"], &{&1["model"], &1["reason"]})

  describe "agy worked example (§5.3): a multi-pool provider spends the pool the router picked" do
    # D1 -> economy. agy's Gemini pool is over its line; its Claude/GPT pool is
    # idle. Claude is the other attached implementer, with its 5h window busy.
    defp worked_pairs(%{agy: agy, claude: claude}),
      do: [{agy, agy_quota(99.0, 0.0)}, {claude, claude_quota(0.7, 0.2)}]

    test "today's single model: the Gemini entry is over its line, so Claude takes the work" do
      s = agy_and_claude(config())

      assert {:ok, selection} = ProviderRouting.select(s.ws, s.task, :main, opts(worked_pairs(s)))

      assert selection.agent_type == :claude
      assert selection.model == nil
      assert {@gemini_flash, "quota_held"} in dropped_reasons(selection.decision)
    end

    test "with the Claude/GPT model listed, agy's second pool is the candidate that wins" do
      tiers = %{"economy" => [@gemini_flash, @claude_sonnet]}
      s = agy_and_claude(config(agy_tier_models: tiers))

      assert {:ok, selection} = ProviderRouting.select(s.ws, s.task, :main, opts(worked_pairs(s)))

      assert selection.agent_type == :gemini
      assert selection.account.id == s.agy.id
      assert selection.family == :anthropic
      assert selection.model == @claude_sonnet
      assert selection.decision["model"] == @claude_sonnet
      assert selection.decision["pool"] == @agy_claude_gpt_pool
      assert selection.decision["outcome"] == "selected"

      # The Gemini model on the over-the-line pool is dropped on its own pool.
      assert {@gemini_flash, "quota_held"} in dropped_reasons(selection.decision)
      assert @claude_sonnet in models(selection.decision["candidates"])
    end

    test "the same choice under scored/enforce" do
      tiers = %{"economy" => [@gemini_flash, @claude_sonnet]}

      s =
        agy_and_claude(
          config(selection: "scored", scoring: %{"mode" => "enforce"}, agy_tier_models: tiers)
        )

      assert {:ok, selection} = ProviderRouting.select(s.ws, s.task, :main, opts(worked_pairs(s)))

      assert selection.account.id == s.agy.id
      assert selection.model == @claude_sonnet
      assert selection.decision["pool"] == @agy_claude_gpt_pool
    end
  end

  describe "entries per (account, model)" do
    test "the Gemini pool wins when it has the room, and the first listed model is the default" do
      tiers = %{"economy" => [@gemini_flash, @claude_sonnet]}
      ws = workspace!(config(agy_tier_models: tiers))
      agy = account!(:antigravity, "agy")
      allow!(ws, agy, 0)

      # Gemini idle, Claude/GPT busy: the router spends Gemini, the default model.
      assert {:ok, selection} =
               ProviderRouting.select(
                 ws,
                 task!(ws, %{difficulty: 1}),
                 :main,
                 opts([{agy, agy_quota(5.0, 60.0)}])
               )

      assert selection.decision["model"] == @gemini_flash
      assert selection.decision["pool"] == @agy_gemini_pool
      # The tier's default model: the spawn resolves it on its own, nothing to carry.
      assert selection.model == nil

      assert Enum.sort(models(selection.decision["candidates"])) ==
               Enum.sort([@gemini_flash, @claude_sonnet])
    end

    test "a one-element list is exactly today's single entry" do
      agy = account!(:antigravity, "agy")
      pairs = [{agy, agy_quota(5.0, 0.0)}]

      decisions =
        for value <- [[@gemini_flash], @gemini_flash] do
          ws = workspace!(config(agy_tier_models: %{"economy" => value}))
          allow!(ws, agy, 0)

          assert {:ok, selection} =
                   ProviderRouting.select(ws, task!(ws, %{difficulty: 1}), :main, opts(pairs))

          assert selection.model == nil
          selection.decision
        end

      [listed, plain] = decisions
      assert models(listed["candidates"]) == [@gemini_flash]
      assert listed["candidates"] == plain["candidates"]
    end

    test "an explicit routed model is never expanded" do
      cfg =
        config(agy_tier_models: %{"economy" => [@gemini_flash, @claude_sonnet]})
        |> put_in(["routing", "rules"], %{"D1" => %{"model" => "gemini-3.1-pro-high"}})
        |> put_in(["agent", "type"], "gemini")

      ws = workspace!(cfg)
      agy = account!(:antigravity, "agy")
      allow!(ws, agy, 0)

      assert {:ok, selection} =
               ProviderRouting.select(
                 ws,
                 task!(ws, %{difficulty: 1}),
                 :main,
                 opts([{agy, agy_quota(5.0, 0.0)}])
               )

      assert models(selection.decision["candidates"]) == ["gemini-3.1-pro-high"]
    end
  end

  describe "allow_upgrade" do
    # agy defaults: economy gemini-3.8-flash-low, standard gemini-3.8-flash-medium,
    # premium gemini-3.1-pro-high, flagship claude-opus-4-6-thinking.
    defp upgrade_candidates(n, difficulty, quota) do
      scoring = if n, do: %{"allow_upgrade" => n}
      ws = workspace!(config(scoring: scoring))
      agy = account!(:antigravity, "agy")
      allow!(ws, agy, 0)

      {:ok, selection} =
        ProviderRouting.select(
          ws,
          task!(ws, %{difficulty: difficulty}),
          :main,
          opts([{agy, quota}])
        )

      selection
    end

    test "off by default: the policy's tier only" do
      selection = upgrade_candidates(nil, 1, agy_quota(5.0, 0.0))
      assert models(selection.decision["candidates"]) == [@gemini_flash]
    end

    test "n tiers above are added behind the policy's own" do
      selection = upgrade_candidates(3, 1, agy_quota(5.0, 0.0))

      assert Enum.sort(models(selection.decision["candidates"])) ==
               Enum.sort([
                 @gemini_flash,
                 "gemini-3.8-flash-medium",
                 "gemini-3.1-pro-high",
                 "claude-opus-4-6-thinking"
               ])
    end

    test "the Gemini pool at its line: an upgrade reaches the idle Claude/GPT pool" do
      selection = upgrade_candidates(3, 1, agy_quota(99.0, 0.0))

      assert selection.model == "claude-opus-4-6-thinking"
      assert selection.decision["pool"] == @agy_claude_gpt_pool
    end

    test "never goes below the policy's tier" do
      # D5 -> premium: flagship is offered above it, nothing below.
      selection = upgrade_candidates(3, 5, agy_quota(5.0, 0.0))

      assert Enum.sort(models(selection.decision["candidates"])) ==
               ["claude-opus-4-6-thinking", "gemini-3.1-pro-high"]
    end
  end

  describe "the pin is (account, family)" do
    defp pinned_task(tiers) do
      ws = workspace!(config(agy_tier_models: tiers))
      agy = account!(:antigravity, "agy")
      allow!(ws, agy, 0)

      task =
        ws
        |> task!(%{difficulty: 1})
        |> Ash.Changeset.for_update(:pin_implementer, %{
          implementer_account_id: agy.id,
          implementer_family: "google"
        })
        |> Ash.update!()

      {ws, agy, task}
    end

    test "a later role stays in the pool the first choice drew on" do
      {ws, agy, task} = pinned_task(%{"economy" => [@gemini_flash, @claude_sonnet]})

      # Gemini is busier than Claude/GPT, yet the task is pinned to the Google family.
      assert {:ok, selection} =
               ProviderRouting.select(ws, task, :fix_pass, opts([{agy, agy_quota(60.0, 5.0)}]))

      assert selection.decision["outcome"] == "pinned"
      assert selection.family == :google
      assert selection.decision["pool"] == @agy_gemini_pool
    end

    test "the pinned account's other pool serves when the pinned family's is held" do
      {ws, agy, task} = pinned_task(%{"economy" => [@gemini_flash, @claude_sonnet]})

      assert {:ok, selection} =
               ProviderRouting.select(ws, task, :fix_pass, opts([{agy, agy_quota(99.0, 5.0)}]))

      assert selection.decision["outcome"] == "pinned"
      assert selection.account.id == agy.id
      assert selection.model == @claude_sonnet
    end
  end

  describe "availability/3" do
    test "an account's capacity is counted once however many models it lists" do
      tiers = %{"economy" => [@gemini_flash, @claude_sonnet]}
      single = workspace!(config())
      multi = workspace!(config(agy_tier_models: tiers))
      agy = account!(:antigravity, "agy")
      allow!(single, agy, 0)
      allow!(multi, agy, 0)
      o = opts([{agy, agy_quota(5.0, 5.0)}])

      one = ProviderRouting.availability(single, task!(single, %{difficulty: 1}), o)
      two = ProviderRouting.availability(multi, task!(multi, %{difficulty: 1}), o)

      assert length(one.available) == 1
      assert length(two.available) == 2
      assert two.capacity == one.capacity
    end
  end

  describe "in-flight reservations (§2.5)" do
    # Claude has 0.45 of headroom, Codex 0.40: the scorer prefers Claude, until
    # a run is in flight on Claude's pool that its snapshot has not seen.
    setup do
      ws = workspace!(config(selection: "scored", scoring: %{"mode" => "enforce"}))
      claude = account!(:claude, "claude")
      codex = account!(:codex, "codex")
      allow!(ws, claude, 0)
      allow!(ws, codex, 1)
      pairs = [{claude, claude_quota(0.40, 0.0)}, {codex, codex_quota(45.0)}]
      %{ws: ws, claude: claude, codex: codex, pairs: pairs}
    end

    defp pick(ws, pairs) do
      {:ok, selection} =
        ProviderRouting.select(ws, task!(ws, %{difficulty: 2}), :main, opts(pairs, pin: false))

      selection
    end

    test "without a reservation the roomier pool wins", %{ws: ws, pairs: pairs} do
      assert pick(ws, pairs).agent_type == :claude
    end

    test "a run reserved on that pool after its snapshot moves the next dispatch off it", ctx do
      PoolReservations.reserve("t-#{ctx.claude.id}", ctx.claude.id, "claude", ahead(5))

      selection = pick(ctx.ws, ctx.pairs)
      assert selection.agent_type == :codex

      claude_row =
        Enum.find(selection.decision["candidates"], &(&1["account_id"] == ctx.claude.id))

      assert claude_row["reserved"] == 1
    end

    test "a reservation older than the snapshot is already in `used` and is ignored", ctx do
      PoolReservations.reserve("t-#{ctx.claude.id}", ctx.claude.id, "claude", ahead(-60))
      assert pick(ctx.ws, ctx.pairs).agent_type == :claude
    end

    test "a reservation on another pool of the same account does not count", ctx do
      PoolReservations.reserve("t-#{ctx.claude.id}", ctx.claude.id, "other-pool", ahead(5))
      assert pick(ctx.ws, ctx.pairs).agent_type == :claude
    end

    test "most_quota ignores reservations: it ranks by headroom alone", ctx do
      ws = workspace!(config())
      allow!(ws, ctx.claude, 0)
      allow!(ws, ctx.codex, 1)
      PoolReservations.reserve("t-#{ctx.claude.id}", ctx.claude.id, "claude", ahead(5))

      assert pick(ws, ctx.pairs).agent_type == :claude
    end

    test "one eligible account: a reservation reorders nothing and holds nothing" do
      ws = workspace!(config(selection: "scored", scoring: %{"mode" => "enforce"}))
      claude = account!(:claude, "solo")
      allow!(ws, claude, 0)
      PoolReservations.reserve("t-#{claude.id}", claude.id, "claude", ahead(5))

      assert pick(ws, [{claude, claude_quota(0.40, 0.0)}]).agent_type == :claude
    end

    test "a reservation never drops a candidate: a pool at its line is still dropped by the gate",
         ctx do
      PoolReservations.reserve("t-#{ctx.claude.id}", ctx.claude.id, "claude", ahead(5))
      pairs = [{ctx.claude, claude_quota(0.40, 0.0)}, {ctx.codex, codex_quota(99.0)}]

      # Codex is over its line (the gate drops it); Claude, though reserved on,
      # is the only feasible candidate and still dispatches.
      assert pick(ctx.ws, pairs).agent_type == :claude
    end
  end

  describe "PoolReservations" do
    test "counts live reservations after the capture and not the excluded task" do
      account = "acct-#{System.unique_integer([:positive])}"
      at = now()
      PoolReservations.reserve("a-#{account}", account, "p", at)
      PoolReservations.reserve("b-#{account}", account, "p", at)

      assert PoolReservations.pending(account, "p", DateTime.add(at, -1), at) == 2
      assert PoolReservations.pending(account, "p", at, at) == 0
      assert PoolReservations.pending(account, "p", nil, at) == 2
      assert PoolReservations.pending(account, "p", nil, at, exclude: "a-#{account}") == 1

      PoolReservations.release("a-#{account}")
      assert PoolReservations.pending(account, "p", nil, at) == 1
    end

    test "a reservation is forgotten after the trust window" do
      account = "acct-#{System.unique_integer([:positive])}"
      at = now()
      PoolReservations.reserve("c-#{account}", account, "p", at)

      later = DateTime.add(at, PoolReservations.ttl_seconds() + 1, :second)
      assert PoolReservations.pending(account, "p", nil, later) == 0
    end
  end

  describe "workspace config validation" do
    defp create_ws(cfg),
      do: Ash.create(Workspace, %{name: "mcv-#{System.unique_integer([:positive])}", config: cfg})

    test "accepts a tier_models list and allow_upgrade" do
      cfg = config(agy_tier_models: %{"economy" => [@gemini_flash, @claude_sonnet]})
      cfg = put_in(cfg, ["routing", "scoring"], %{"allow_upgrade" => 2})
      assert {:ok, _} = create_ws(cfg)
    end

    test "rejects an empty list, a junk entry and a bad allow_upgrade" do
      for {cfg, expect} <- [
            {config(agy_tier_models: %{"economy" => []}), "non-empty list"},
            {config(agy_tier_models: %{"economy" => ["ok", ""]}), "non-empty list"},
            {config(agy_tier_models: %{"economy" => 7}), "non-empty model name string"},
            {put_in(config(), ["routing", "scoring"], %{"allow_upgrade" => -1}),
             "routing.scoring.allow_upgrade"},
            {put_in(config(), ["routing", "scoring"], %{"allow_upgrade" => "1"}),
             "routing.scoring.allow_upgrade"}
          ] do
        assert {:error, error} = create_ws(cfg)
        assert Exception.message(error) =~ expect
      end
    end
  end
end
