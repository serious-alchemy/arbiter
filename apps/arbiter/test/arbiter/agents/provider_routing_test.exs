defmodule Arbiter.Agents.ProviderRoutingTest do
  @moduledoc """
  bd-40pzpj: pick the implementer's provider account by most quota left.

  Candidates are the workspace's attached accounts allowed for the
  implementer role (AC2); unavailable ones are dropped with a reason (AC3);
  the rest are ranked by headroom against pace (AC4); the pick is pinned on
  the task and reused, with a recorded fallback (AC6); an explicit provider
  override still wins (AC8).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Agents
  alias Arbiter.Agents.{CredentialWatchdog, ProviderPool, ProviderRouting, SecurityPolicy}
  alias Arbiter.Quota.{AnthropicQuota, CodexQuota, GoogleQuota}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workers.Run

  @most_quota %{"routing" => %{"provider_selection" => "most_quota"}}

  setup do
    on_exit(fn -> :ets.delete_all_objects(:arbiter_provider_circuit_breakers) end)
    :ok
  end

  # ---- fixtures -------------------------------------------------------------

  defp workspace!(config \\ @most_quota) do
    Ash.create!(Workspace, %{name: "pr-#{System.unique_integer([:positive])}", config: config})
  end

  defp account!(provider, slug, attrs \\ %{}) do
    Ash.create!(
      ProviderAccount,
      Map.merge(
        %{provider: provider, slug: "#{slug}-#{System.unique_integer([:positive])}"},
        attrs
      )
    )
  end

  defp link!(ws, account, attrs) do
    Ash.create!(
      WorkspaceProviderAccount,
      Map.merge(
        %{workspace_id: ws.id, provider: account.provider, provider_account_id: account.id},
        attrs
      )
    )
  end

  defp allow!(ws, account, position, attrs \\ %{}),
    do: link!(ws, account, Map.put(attrs, :implementer_position, position))

  defp task!(ws, attrs \\ %{}),
    do: Ash.create!(Issue, Map.merge(%{title: "route me", workspace_id: ws.id}, attrs))

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp ahead(secs), do: DateTime.add(now(), secs, :second)

  defp claude_quota(u5, u7 \\ 0.0) do
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

  defp codex_quota(session_pct, weekly_pct \\ 0.0) do
    %CodexQuota{
      provider: "codex",
      session_used_percent: session_pct,
      session_reset_at: ahead(3_600),
      weekly_used_percent: weekly_pct,
      weekly_reset_at: ahead(302_400),
      limit_reached: false,
      captured_at: now()
    }
  end

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

  # Quota by account id, so each test states exactly what every candidate reads.
  defp quotas(pairs) do
    by_id = Map.new(pairs, fn {account, quota} -> {account.id, quota} end)
    fn account -> Map.get(by_id, account.id) end
  end

  defp opts(pairs, extra \\ []),
    do: Keyword.merge([quota_fun: quotas(pairs), gemini_code: "antigravity"], extra)

  # A process registered under the worker registry with the dispatch value
  # `Arbiter.Worker.init/1` records — enough for `Concurrency.live_count/2`.
  defp author_worker!(ws, key, provider) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(Arbiter.Worker.Registry, key, nil)
        :ok = Arbiter.Worker.Registry.put_dispatch(key, ws.id, provider)
        send(test, {:registered, self()})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:registered, ^pid}
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp slugs(entries), do: Enum.map(entries, & &1["account_slug"])
  defp reasons(decision), do: Map.new(decision["dropped"], &{&1["account_slug"], &1["reason"]})

  # ---- config ---------------------------------------------------------------

  describe "routing.provider_selection" do
    test "is off by default and on only for most_quota" do
      refute ProviderRouting.enabled?(workspace!(%{}))
      refute ProviderRouting.enabled?(nil)

      refute ProviderRouting.enabled?(
               workspace!(%{"routing" => %{"provider_selection" => "failover"}})
             )

      assert ProviderRouting.enabled?(workspace!())
    end

    test "the workspace config validator accepts failover / most_quota and rejects anything else" do
      assert {:ok, _} =
               Ash.create(Workspace, %{
                 name: "pr-ok-#{System.unique_integer([:positive])}",
                 config: %{"routing" => %{"provider_selection" => "failover"}}
               })

      assert {:error, error} =
               Ash.create(Workspace, %{
                 name: "pr-bad-#{System.unique_integer([:positive])}",
                 config: %{"routing" => %{"provider_selection" => "most_credit"}}
               })

      assert Exception.message(error) =~ "routing.provider_selection must be one of"
    end
  end

  # ---- AC2: the candidate set ------------------------------------------------

  describe "candidates (AC2)" do
    test "an account attached but not allowed for the implementer is excluded; an allowed one is included" do
      ws = workspace!()
      attached_only = account!(:claude, "attached-only")
      allowed = account!(:codex, "allowed")
      link!(ws, attached_only, %{reviewer_position: 0})
      allow!(ws, allowed, 0)

      decision = ProviderRouting.evaluate(ws, task!(ws), opts([]))

      assert slugs(decision["candidates"]) == [allowed.slug]
      refute attached_only.slug in slugs(decision["dropped"])
    end

    test "with nothing allowed for the implementer there is no candidate and dispatch stays legacy" do
      ws = workspace!()
      link!(ws, account!(:claude, "metering-only"), %{})

      assert {:legacy, decision} = ProviderRouting.select(ws, task!(ws), :main, opts([]))
      assert decision["outcome"] == "no_candidate"
      assert decision["candidates"] == []
    end
  end

  # ---- AC3: availability ----------------------------------------------------

  describe "availability (AC3)" do
    setup do
      ws = workspace!()
      healthy = account!(:claude, "healthy")
      allow!(ws, healthy, 0)
      %{ws: ws, healthy: healthy}
    end

    test "a disabled account is dropped", %{ws: ws} do
      parked = account!(:codex, "parked", %{enabled: false})
      allow!(ws, parked, 1)

      decision = ProviderRouting.evaluate(ws, task!(ws), opts([]))
      assert reasons(decision)[parked.slug] == "disabled"
    end

    test "a paused account is dropped with reason paused (bd-5ef587)", %{ws: ws} do
      paused = account!(:codex, "paused")
      allow!(ws, paused, 1)
      {:ok, _} = Arbiter.Providers.Pause.pause(paused.id, reason: "jail escape", by: "test")

      decision = ProviderRouting.evaluate(ws, task!(ws), opts([]))
      assert reasons(decision)[paused.slug] == "paused"
    end

    test "a paused provider drops every account on it", %{ws: ws} do
      a = account!(:codex, "a")
      allow!(ws, a, 1)
      {:ok, _} = Arbiter.Providers.Pause.pause("codex", reason: "x", by: "test")

      decision = ProviderRouting.evaluate(ws, task!(ws), opts([]))
      assert reasons(decision)[a.slug] == "paused"
    end

    test "a merged account is dropped", %{ws: ws, healthy: healthy} do
      merged = account!(:codex, "merged", %{merged_into_id: healthy.id})
      allow!(ws, merged, 1)

      decision = ProviderRouting.evaluate(ws, task!(ws), opts([]))
      assert reasons(decision)[merged.slug] == "merged"
    end

    test "an account the gate holds on its own policy is dropped", %{ws: ws} do
      held = account!(:codex, "held", %{quota_config: %{"throttle_threshold" => 0.5}})
      allow!(ws, held, 1)

      decision = ProviderRouting.evaluate(ws, task!(ws), opts([{held, codex_quota(60.0)}]))

      assert reasons(decision)[held.slug] == "quota_held"

      assert Enum.find(decision["dropped"], &(&1["account_slug"] == held.slug))["detail"] =~
               "ceiling 50%"
    end

    test "an account the gate holds only on the workspace's stricter policy is dropped" do
      ws =
        workspace!(
          Map.put(@most_quota, "quota", %{
            "throttle_threshold" => 0.3,
            "on_exhaustion" => "throttle"
          })
        )

      held = account!(:claude, "ws-held")
      allow!(ws, held, 0)

      decision = ProviderRouting.evaluate(ws, task!(ws), opts([{held, claude_quota(0.4)}]))
      assert reasons(decision)[held.slug] == "quota_held"
    end

    test "a paced account ahead of its pace is dropped though its flat ceiling has room" do
      # A fresh workspace: one account per provider, and setup's is Claude.
      ws = workspace!()

      paced =
        account!(:claude, "paced", %{
          quota_config: %{"threshold_mode" => "paced", "paced_floor" => 0.35}
        })

      allow!(ws, paced, 0)

      # 5h window reset 4.9h out: elapsed ≈ 0.02, so the paced line is the 0.35
      # floor — 0.40 is over it, though far under the 0.85 flat default.
      quota = %{claude_quota(0.40) | reset_5h_at: ahead(17_640)}
      decision = ProviderRouting.evaluate(ws, task!(ws), opts([{paced, quota}]))

      assert reasons(decision)[paced.slug] == "quota_held"
    end

    test "an auth-expired adapter's account is dropped", %{ws: ws} do
      codex = account!(:codex, "expired")
      allow!(ws, codex, 1)

      CredentialWatchdog.mark_expired(Agents.Codex, %Arbiter.Worker.StopReason{
        category: :auth_expired,
        summary: "credentials expired"
      })

      _ = :sys.get_state(CredentialWatchdog)

      on_exit(fn ->
        CredentialWatchdog.clear(Agents.Codex)
        _ = :sys.get_state(CredentialWatchdog)
      end)

      decision = ProviderRouting.evaluate(ws, task!(ws), opts([]))
      assert reasons(decision)[codex.slug] == "auth_expired"
    end

    test "a circuit-broken adapter's account is dropped", %{ws: ws} do
      codex = account!(:codex, "exhausted")
      allow!(ws, codex, 1)
      ProviderPool.mark_exhausted(:codex)

      decision = ProviderRouting.evaluate(ws, task!(ws), opts([]))
      assert reasons(decision)[codex.slug] == "circuit_broken"
    end

    test "an account at its max_concurrent is dropped", %{ws: ws} do
      full = account!(:codex, "full", %{max_concurrent: 0})
      allow!(ws, full, 1)

      decision = ProviderRouting.evaluate(ws, task!(ws), opts([]))
      assert reasons(decision)[full.slug] == "at_capacity"
    end

    test "an account at this workspace's concurrency share is dropped", %{ws: ws} do
      shared = account!(:codex, "shared", %{max_concurrent: 8})
      allow!(ws, shared, 1, %{share: 0})

      decision = ProviderRouting.evaluate(ws, task!(ws), opts([]))
      assert reasons(decision)[shared.slug] == "at_capacity"
    end

    test "under a :strict scope an adapter that cannot confine writes is dropped", %{
      ws: ws,
      healthy: healthy
    } do
      agy = account!(:antigravity, "unjailed")
      allow!(ws, agy, 1)

      strict = SecurityPolicy.resolve(nil, %{"permissions" => %{"mode" => "strict"}})

      confinement = fn
        Agents.Claude, _policy -> :permission_layer
        _adapter, _policy -> :none
      end

      decision =
        ProviderRouting.evaluate(
          ws,
          task!(ws),
          opts([], security: strict, write_confinement: confinement)
        )

      assert reasons(decision)[agy.slug] == "write_confinement_none"
      assert slugs(decision["candidates"]) == [healthy.slug]

      # Outside :strict the same account is a candidate.
      auto = SecurityPolicy.resolve(nil, %{})

      relaxed =
        ProviderRouting.evaluate(
          ws,
          task!(ws),
          opts([], security: auto, write_confinement: confinement)
        )

      assert agy.slug in slugs(relaxed["candidates"])
    end

    test "agy and codex count as available on a healthy probe with no account credential row", %{
      ws: ws
    } do
      agy = account!(:antigravity, "agy-login")
      codex = account!(:codex, "codex-login")
      allow!(ws, agy, 1)
      allow!(ws, codex, 2)

      decision = ProviderRouting.evaluate(ws, task!(ws), opts([]))

      assert agy.slug in slugs(decision["candidates"])
      assert codex.slug in slugs(decision["candidates"])
      assert decision["dropped"] == []
    end

    test "a Google account whose CLI is not the one installed is dropped", %{ws: ws} do
      agy = account!(:antigravity, "agy-not-installed")
      allow!(ws, agy, 1)

      # No agy on this host: since bd-ac53wz the `gemini` adapter's quota code
      # is `nil` then (the upstream Gemini CLI provider is gone).
      decision = ProviderRouting.evaluate(ws, task!(ws), opts([], gemini_code: nil))
      assert reasons(decision)[agy.slug] == "cli_unavailable"
    end
  end

  # ---- AC4: ranking ---------------------------------------------------------

  describe "availability/3 (bd-3fvue3)" do
    test "is what evaluate/3 records, plus each candidate's capacity and their sum" do
      ws = workspace!()
      claude = account!(:claude, "cap", %{max_concurrent: 2})
      codex = account!(:codex, "cap", %{max_concurrent: 3})
      allow!(ws, claude, 0)
      allow!(ws, codex, 1)
      author_worker!(ws, "cap-worker", "claude")

      o = opts([{claude, claude_quota(0.1)}, {codex, codex_quota(10.0)}], now: now())
      view = ProviderRouting.availability(ws, nil, o)

      assert view.record == ProviderRouting.evaluate(ws, nil, o)
      assert view.available |> Enum.map(& &1.capacity) |> Enum.sort() == [1, 3]
      assert view.dropped == []
      assert view.capacity == 4
    end

    test "a dropped candidate's capacity does not count" do
      ws = workspace!()
      claude = account!(:claude, "open", %{max_concurrent: 2})

      held =
        account!(:codex, "held", %{
          max_concurrent: 4,
          quota_config: %{"throttle_threshold" => 0.5}
        })

      allow!(ws, claude, 0)
      allow!(ws, held, 1)

      view =
        ProviderRouting.availability(
          ws,
          nil,
          opts([{claude, claude_quota(0.1)}, {held, codex_quota(60.0)}])
        )

      assert [%{reason: "quota_held"} = dropped] = view.dropped
      assert dropped.account.id == held.id
      assert view.capacity == 2
    end

    test "is :unlimited when any available candidate has no ceiling, 0 with none available" do
      ws = workspace!()
      free = account!(:claude, "free")
      allow!(ws, free, 0)

      assert ProviderRouting.availability(ws, nil, opts([])).capacity == :unlimited

      none = workspace!()
      parked = account!(:claude, "parked", %{enabled: false})
      allow!(none, parked, 0)

      view = ProviderRouting.availability(none, nil, opts([]))
      assert view.available == []
      assert view.capacity == 0
    end
  end

  describe "ranking by headroom (AC4)" do
    test "the account with the most headroom against its threshold wins" do
      ws = workspace!()
      claude = account!(:claude, "busy")
      codex = account!(:codex, "idle")
      allow!(ws, claude, 0)
      allow!(ws, codex, 1)

      # claude: 0.85 − 0.70 = 0.15; codex: 0.85 − 0.10 = 0.75.
      pairs = [{claude, claude_quota(0.70)}, {codex, codex_quota(10.0)}]

      assert {:ok, selection} = ProviderRouting.select(ws, task!(ws), :main, opts(pairs))
      assert selection.agent_type == :codex
      assert selection.account.id == codex.id
      assert selection.family == :openai
      assert selection.decision["outcome"] == "selected"

      assert [first, second] = selection.decision["candidates"]
      assert first["account_slug"] == codex.slug
      assert_in_delta first["headroom"], 0.75, 1.0e-4
      assert_in_delta second["headroom"], 0.15, 1.0e-4
    end

    test "a paced account's headroom is measured against its pace, not the flat ceiling" do
      ws = workspace!()
      paced = account!(:claude, "paced", %{quota_config: %{"threshold_mode" => "paced"}})
      flat = account!(:codex, "flat")
      allow!(ws, paced, 0)
      allow!(ws, flat, 1)

      # paced claude halfway through: threshold 0.5 − 0.30 = 0.20.
      # flat codex: 0.85 − 0.60 = 0.25 → codex wins, though claude is less used.
      pairs = [{paced, claude_quota(0.30)}, {flat, codex_quota(60.0)}]

      assert {:ok, selection} = ProviderRouting.select(ws, task!(ws), :main, opts(pairs))
      assert selection.account.id == flat.id
    end

    test "ties go to the configured account order" do
      ws = workspace!()
      second = account!(:codex, "second")
      first = account!(:claude, "first")
      allow!(ws, first, 0)
      allow!(ws, second, 1)

      pairs = [{first, claude_quota(0.25)}, {second, codex_quota(25.0)}]

      assert {:ok, selection} = ProviderRouting.select(ws, task!(ws), :main, opts(pairs))
      assert selection.account.id == first.id
    end

    test "an account with no quota reading ranks after every known one" do
      ws = workspace!()
      unknown = account!(:claude, "unknown")
      known = account!(:codex, "known")
      allow!(ws, unknown, 0)
      allow!(ws, known, 1)

      assert {:ok, selection} =
               ProviderRouting.select(ws, task!(ws), :main, opts([{known, codex_quota(80.0)}]))

      assert selection.account.id == known.id
      assert Enum.at(selection.decision["candidates"], 1)["headroom"] == nil
    end

    test "agy's two pools: the tier's model decides which pool the headroom is read from" do
      config =
        @most_quota
        |> put_in(["routing", "policy"], "by_difficulty")
        |> put_in(["routing", "rules"], %{"D5" => %{"model_tier" => "flagship"}})

      ws = workspace!(config)
      agy = account!(:antigravity, "agy")
      codex = account!(:codex, "codex")
      allow!(ws, agy, 0)
      allow!(ws, codex, 1)

      # Gemini pool nearly spent, Claude-and-GPT pool nearly idle; codex middling.
      pairs = [{agy, agy_quota(80.0, 5.0)}, {codex, codex_quota(40.0)}]

      # D2 → standard → gemini-3.8-flash-medium → the spent Gemini pool: codex wins.
      assert {:ok, d2} =
               ProviderRouting.select(ws, task!(ws, %{difficulty: 2}), :main, opts(pairs))

      assert d2.agent_type == :codex

      agy_d2 = Enum.find(d2.decision["candidates"], &(&1["account_slug"] == agy.slug))
      assert agy_d2["pool"] == "antigravity:gemini_models"
      assert agy_d2["family"] == "google"

      # D5 → flagship → claude-opus-4-6-thinking → the idle Claude pool: agy wins,
      # as Anthropic-family work.
      assert {:ok, d5} =
               ProviderRouting.select(ws, task!(ws, %{difficulty: 5}), :main, opts(pairs))

      assert d5.agent_type == :gemini
      assert d5.family == :anthropic
      assert d5.decision["pool"] == "antigravity:claude_and_gpt_models"
      assert d5.decision["model"] == "claude-opus-4-6-thinking"
    end
  end

  # ---- difficulty within the chosen family -----------------------------------

  describe "difficulty picks the model within the chosen family" do
    for {difficulty, claude_model, codex_model} <- [
          {1, "haiku", "gpt-5.6-luna"},
          {4, "opus", "gpt-5.6-terra"}
        ] do
      test "D#{difficulty} resolves the tier's model in whichever family wins" do
        ws = workspace!(put_in(@most_quota, ["routing", "policy"], "by_difficulty"))
        claude = account!(:claude, "c")
        codex = account!(:codex, "x")
        allow!(ws, claude, 0)
        allow!(ws, codex, 1)
        task = task!(ws, %{difficulty: unquote(difficulty)})

        claude_wins = [{claude, claude_quota(0.1)}, {codex, codex_quota(70.0)}]
        codex_wins = [{claude, claude_quota(0.7)}, {codex, codex_quota(10.0)}]

        assert {:ok, a} = ProviderRouting.select(ws, task, :main, opts(claude_wins, pin: false))
        assert a.agent_type == :claude
        assert a.decision["model"] == unquote(claude_model)

        assert {:ok, b} = ProviderRouting.select(ws, task, :main, opts(codex_wins, pin: false))
        assert b.agent_type == :codex
        assert b.decision["model"] == unquote(codex_model)
      end
    end
  end

  # ---- AC6: pinning ----------------------------------------------------------

  describe "the implementer pin (AC6)" do
    setup do
      ws = workspace!()
      claude = account!(:claude, "pin-claude")
      codex = account!(:codex, "pin-codex")
      agy = account!(:antigravity, "pin-agy")
      allow!(ws, claude, 0)
      allow!(ws, codex, 1)
      allow!(ws, agy, 2)
      %{ws: ws, claude: claude, codex: codex, agy: agy}
    end

    test "the first routed dispatch pins the account and family on the task", %{
      ws: ws,
      codex: codex
    } do
      task = task!(ws)
      pairs = [{codex, codex_quota(5.0)}]

      assert {:ok, _} = ProviderRouting.select(ws, task, :main, opts(pairs))

      pinned = Ash.get!(Issue, task.id)
      assert pinned.implementer_account_id == codex.id
      assert pinned.implementer_family == "openai"
    end

    test "a later role reuses the pin even when another account now has more headroom", %{
      ws: ws,
      claude: claude,
      codex: codex
    } do
      task = task!(ws)
      assert {:ok, _} = ProviderRouting.select(ws, task, :main, opts([{codex, codex_quota(5.0)}]))

      later = [{claude, claude_quota(0.0)}, {codex, codex_quota(60.0)}]

      assert {:ok, again} =
               ProviderRouting.select(ws, Ash.get!(Issue, task.id), :resume, opts(later))

      assert again.account.id == codex.id
      assert again.decision["outcome"] == "pinned"
      assert again.decision["role"] == "resume"
    end

    test "a follow-up role does not count the task's own live worker against the pin" do
      # The pin's only slot is held by the task's own author worker — parked
      # through a ReviewGate round, still registered — and by nothing else.
      ws = workspace!()
      shared = account!(:claude, "pin-shared", %{max_concurrent: 4})
      codex = account!(:codex, "pin-share-codex")
      allow!(ws, shared, 0, %{share: 1})
      allow!(ws, codex, 1)
      task = task!(ws)
      pairs = [{shared, claude_quota(0.0)}, {codex, codex_quota(5.0)}]

      assert {:ok, first} = ProviderRouting.select(ws, task, :main, opts(pairs))
      assert first.account.id == shared.id

      author_worker!(ws, task.id, "claude")
      task = Ash.get!(Issue, task.id)

      assert {:ok, round} =
               ProviderRouting.select(ws, task, :review_gate_implementer, opts(pairs))

      assert round.account.id == shared.id
      assert round.decision["outcome"] == "pinned"

      # Another task's worker in the same slot still fills it.
      other = task!(ws)
      assert {:ok, _} = ProviderRouting.select(ws, other, :main, opts(pairs))
      assert Ash.get!(Issue, other.id).implementer_account_id == codex.id

      decision = ProviderRouting.evaluate(ws, task, opts(pairs))
      assert reasons(decision)[shared.slug] == "at_capacity"
    end

    test "an unavailable pin falls back to the best account outside the reviewer's family", %{
      ws: ws,
      claude: claude,
      codex: codex,
      agy: agy
    } do
      task = task!(ws)
      assert {:ok, _} = ProviderRouting.select(ws, task, :main, opts([{codex, codex_quota(5.0)}]))

      # The pinned codex is now held; claude has the most headroom but is the
      # reviewer's family, so agy (google) is the fallback.
      pairs = [
        {codex, codex_quota(99.0)},
        {claude, claude_quota(0.0)},
        {agy, agy_quota(50.0, 0.0)}
      ]

      assert {:ok, fallback} =
               ProviderRouting.select(
                 ws,
                 Ash.get!(Issue, task.id),
                 :fix_pass,
                 opts(pairs, reviewer_family: :anthropic)
               )

      assert fallback.account.id == agy.id
      assert fallback.decision["outcome"] == "fallback"
      assert fallback.decision["fallback"] =~ codex.slug
      assert fallback.decision["fallback"] =~ "quota_held"
      assert fallback.decision["excluded_family"] == "anthropic"

      # The pin itself is kept: the next role returns to codex once it frees up.
      assert Ash.get!(Issue, task.id).implementer_account_id == codex.id
    end

    test "the reviewer's family is used when it is the only option left", %{
      ws: ws,
      claude: claude,
      codex: codex,
      agy: agy
    } do
      task = task!(ws)
      assert {:ok, _} = ProviderRouting.select(ws, task, :main, opts([{codex, codex_quota(5.0)}]))

      pairs = [
        {codex, codex_quota(99.0)},
        {claude, claude_quota(0.0)},
        {agy, agy_quota(99.0, 99.0)}
      ]

      assert {:ok, fallback} =
               ProviderRouting.select(
                 ws,
                 Ash.get!(Issue, task.id),
                 :fix_pass,
                 opts(pairs, reviewer_family: :anthropic)
               )

      assert fallback.account.id == claude.id
      assert fallback.decision["outcome"] == "fallback"
      assert fallback.decision["excluded_family"] == nil
    end

    test "the task's pinned cross-family reviewer family is excluded first (bd-a1ke2c)", %{
      ws: ws,
      claude: claude,
      codex: codex,
      agy: agy
    } do
      task = task!(ws)
      assert {:ok, _} = ProviderRouting.select(ws, task, :main, opts([{codex, codex_quota(5.0)}]))

      task
      |> Ash.Changeset.for_update(:pin_reviewer, %{reviewer_family: "anthropic"})
      |> Ash.update!()

      pairs = [
        {codex, codex_quota(99.0)},
        {claude, claude_quota(0.0)},
        {agy, agy_quota(50.0, 0.0)}
      ]

      assert {:ok, fallback} =
               ProviderRouting.select(ws, Ash.get!(Issue, task.id), :conflict, opts(pairs))

      assert fallback.account.id == agy.id
      assert fallback.decision["excluded_family"] == "anthropic"
    end

    test "the reviewer's family is read off the task's latest review run", %{
      ws: ws,
      claude: claude,
      codex: codex,
      agy: agy
    } do
      task = task!(ws)
      assert {:ok, _} = ProviderRouting.select(ws, task, :main, opts([{codex, codex_quota(5.0)}]))

      Ash.create!(Run, %{
        task_id: task.id <> "#review",
        base_task_id: task.id,
        repo: "r",
        workspace_id: ws.id,
        kind: :review,
        provider: "claude",
        model: "claude-opus-4-8",
        state: :finished,
        outcome: :succeeded,
        started_at: DateTime.utc_now()
      })

      pairs = [
        {codex, codex_quota(99.0)},
        {claude, claude_quota(0.0)},
        {agy, agy_quota(50.0, 0.0)}
      ]

      assert {:ok, fallback} =
               ProviderRouting.select(ws, Ash.get!(Issue, task.id), :conflict, opts(pairs))

      assert fallback.account.id == agy.id
    end
  end

  # ---- AC8: override ---------------------------------------------------------

  describe "a dispatch-time provider override (AC8)" do
    test "wins over the headroom pick and is recorded as an override, without pinning" do
      ws = workspace!()
      claude = account!(:claude, "o-claude")
      codex = account!(:codex, "o-codex")
      allow!(ws, claude, 0)
      allow!(ws, codex, 1)
      task = task!(ws)

      pairs = [{claude, claude_quota(0.0)}, {codex, codex_quota(80.0)}]

      assert {:ok, selection} =
               ProviderRouting.select(ws, task, :main, opts(pairs, override: :codex))

      assert selection.agent_type == :codex
      assert selection.account.id == codex.id
      assert selection.decision["outcome"] == "override"
      assert selection.decision["override"] =~ "codex"
      # The headroom evaluation is still on the record.
      assert length(selection.decision["candidates"]) == 2
      assert Ash.get!(Issue, task.id).implementer_account_id == nil
    end
  end
end
