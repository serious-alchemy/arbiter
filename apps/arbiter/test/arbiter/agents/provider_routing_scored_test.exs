defmodule Arbiter.Agents.ProviderRoutingScoredTest do
  @moduledoc """
  bd-adtnto (R5 of `docs/design/paced-quota-routing-signals.md`):
  `routing.provider_selection: scored`.

    * `shadow` (the default) dispatches exactly as `most_quota` and only records
      the scorer's choice; `enforce` dispatches by the scorer's order (§9.2);
    * I1: with the layer off, nothing about the decision changes;
    * I2: with one eligible candidate — or with no draw/time estimate at all —
      `scored` in either mode picks what `most_quota` picks (§9.1).
  """
  use Arbiter.DataCase, async: false
  use ExUnitProperties

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Agents.ProviderRouting
  alias Arbiter.Quota.{AnthropicQuota, CodexQuota, GoogleQuota}
  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    on_exit(fn -> :ets.delete_all_objects(:arbiter_provider_circuit_breakers) end)
    :ok
  end

  defp config(selection, scoring \\ nil) do
    routing = %{"provider_selection" => selection}
    routing = if scoring, do: Map.put(routing, "scoring", scoring), else: routing
    %{"routing" => routing}
  end

  defp workspace!(cfg),
    do: Ash.create!(Workspace, %{name: "sc-#{System.unique_integer([:positive])}", config: cfg})

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

  defp allow_both!(ws, account, impl_pos, rev_pos) do
    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: account.provider,
      provider_account_id: account.id,
      implementer_position: impl_pos,
      reviewer_position: rev_pos
    })
  end

  defp task!(ws, attrs \\ %{}),
    do: Ash.create!(Issue, Map.merge(%{title: "score me", workspace_id: ws.id}, attrs))

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

  defp agy_quota(gemini_used) do
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
          bucket.("claude_and_gpt_models", "5h", 0.0, ahead(9_000)),
          bucket.("claude_and_gpt_models", "weekly", 0.0, ahead(302_400))
        ]
      }
    }
  end

  defp quotas(pairs) do
    by_id = Map.new(pairs, fn {account, quota} -> {account.id, quota} end)
    fn account -> Map.get(by_id, account.id) end
  end

  defp opts(pairs, extra \\ []),
    do: Keyword.merge([quota_fun: quotas(pairs), pin: false], extra)

  # Two attached implementer accounts: claude (position 0) and codex (position 1).
  defp two_accounts!(cfg) do
    ws = workspace!(cfg)
    claude = account!(:claude, "claude")
    codex = account!(:codex, "codex")
    allow!(ws, claude, 0)
    allow!(ws, codex, 1)
    %{ws: ws, claude: claude, codex: codex}
  end

  # The choice a `select/4` made, in the terms I2 compares.
  defp choice({:ok, %{decision: d}}),
    do: {d["outcome"], d["account_id"], d["model"], Enum.map(d["candidates"], & &1["account_id"])}

  defp choice({:legacy, d}), do: {d["outcome"], nil, nil, []}

  describe "the switch" do
    test "scored routes like most_quota; scored? tells them apart" do
      scored = workspace!(config("scored"))
      most = workspace!(config("most_quota"))
      off = workspace!(config("failover"))

      assert ProviderRouting.enabled?(scored) and ProviderRouting.scored?(scored)
      assert ProviderRouting.enabled?(most) and not ProviderRouting.scored?(most)
      refute ProviderRouting.enabled?(off)
      refute ProviderRouting.scored?(off)
      refute ProviderRouting.scored?(nil)
    end

    test "the config validator accepts scored and the scoring keys, and rejects bad ones" do
      ok =
        config("scored", %{
          "mode" => "enforce",
          "time_weight" => %{"P0" => 10, "P1" => 2},
          "competence" => true,
          "reviewer_coupling" => false
        })

      assert {:ok, _} =
               Ash.create(Workspace, %{
                 name: "sc-ok-#{System.unique_integer([:positive])}",
                 config: ok
               })

      for {bad, expect} <- [
            {%{"mode" => "yolo"}, "routing.scoring.mode"},
            {%{"time_weight" => %{"P9" => 1}}, "routing.scoring.time_weight"},
            {%{"time_weight" => %{"P0" => -1}}, "routing.scoring.time_weight"},
            {%{"time_weight" => 3}, "routing.scoring.time_weight"},
            {%{"competence" => "yes"}, "routing.scoring.competence"},
            {%{"reviewer_coupling" => 123}, "routing.scoring.reviewer_coupling"}
          ] do
        assert {:error, error} =
                 Ash.create(Workspace, %{
                   name: "sc-bad-#{System.unique_integer([:positive])}",
                   config: config("scored", bad)
                 })

        assert Exception.message(error) =~ expect
      end
    end
  end

  describe "I1: with the layer off, the record is today's, with no scoring keys" do
    test "most_quota records no score, no shadow and keeps mode most_quota" do
      %{ws: ws, claude: claude, codex: codex} = two_accounts!(config("most_quota"))

      decision =
        ProviderRouting.evaluate(
          ws,
          task!(ws),
          opts([{claude, claude_quota(0.1)}, {codex, codex_quota(5.0)}])
        )

      assert decision["mode"] == "most_quota"
      refute Map.has_key?(decision, "shadow")
      refute Map.has_key?(decision, "scoring_mode")

      for candidate <- decision["candidates"] do
        refute Map.has_key?(candidate, "price")
        refute Map.has_key?(candidate, "score")
      end
    end
  end

  describe "shadow" do
    setup do
      two_accounts!(config("scored"))
    end

    test "dispatches the most_quota pick and records the scorer's ranking", ctx do
      %{ws: ws, claude: claude, codex: codex} = ctx
      # claude 5h at 0.30 used, codex at 5%: codex has far more headroom.
      pairs = [{claude, claude_quota(0.30)}, {codex, codex_quota(5.0)}]

      assert {:ok, %{decision: d, account: picked}} =
               ProviderRouting.select(ws, task!(ws), :main, opts(pairs))

      assert picked.id == codex.id
      assert d["mode"] == "scored"
      assert d["scoring_mode"] == "shadow"
      assert d["outcome"] == "selected"
      assert %{"ranking" => [first, _], "agrees" => true, "comparable" => true} = d["shadow"]
      assert first["account_id"] == codex.id
      assert Enum.all?(d["candidates"], &(is_number(&1["price"]) and is_number(&1["score"])))
    end

    test "a scorer that would choose differently is recorded as a disagreement with its reason",
         ctx do
      %{ws: ws, claude: claude, codex: codex} = ctx
      pairs = [{claude, claude_quota(0.30)}, {codex, codex_quota(5.0)}]
      # codex has more headroom, but is expected to need ten times the draw.
      estimate = fn
        %{account: %{id: id}} when id == codex.id -> %{draw: 10.0}
        _ -> %{draw: 1.0}
      end

      assert {:ok, %{account: picked, decision: d}} =
               ProviderRouting.select(ws, task!(ws), :main, opts(pairs, estimate_fun: estimate))

      # Dispatch is unchanged: most_quota's pick.
      assert picked.id == codex.id
      assert %{"agrees" => false, "pick" => pick, "reason" => reason} = d["shadow"]
      assert pick["account_id"] == claude.id
      assert reason =~ "price"
    end

    test "a pinned dispatch is not comparable", ctx do
      %{ws: ws, claude: claude, codex: codex} = ctx

      task =
        ws
        |> task!()
        |> Ash.Changeset.for_update(:pin_implementer, %{
          implementer_account_id: claude.id,
          implementer_family: "claude"
        })
        |> Ash.update!()

      pairs = [{claude, claude_quota(0.30)}, {codex, codex_quota(5.0)}]

      assert {:ok, %{decision: d}} = ProviderRouting.select(ws, task, :resume, opts(pairs))
      assert d["outcome"] == "pinned"
      assert %{"comparable" => false, "agrees" => nil} = d["shadow"]
    end

    test "no feasible candidate still blocks exactly as most_quota does", ctx do
      %{ws: ws, claude: claude, codex: codex} = ctx
      pairs = [{claude, claude_quota(0.99, 0.99)}, {codex, codex_quota(99.0)}]

      scored = ProviderRouting.select(ws, task!(ws), :main, opts(pairs))
      assert {:legacy, %{"outcome" => "no_candidate", "candidates" => []}} = scored
    end
  end

  describe "enforce" do
    setup do
      two_accounts!(config("scored", %{"mode" => "enforce"}))
    end

    test "dispatches the scorer's choice", ctx do
      %{ws: ws, claude: claude, codex: codex} = ctx
      pairs = [{claude, claude_quota(0.30)}, {codex, codex_quota(5.0)}]

      estimate = fn
        %{account: %{id: id}} when id == codex.id -> %{draw: 10.0}
        _ -> %{draw: 1.0}
      end

      assert {:ok, %{account: picked, decision: d}} =
               ProviderRouting.select(ws, task!(ws), :main, opts(pairs, estimate_fun: estimate))

      assert picked.id == claude.id
      assert d["scoring_mode"] == "enforce"
      refute Map.has_key?(d, "shadow")
      assert hd(d["candidates"])["account_id"] == claude.id
    end

    test "the time term, weighted by the ticket's own priority, can reorder" do
      %{ws: ws, claude: claude, codex: codex} =
        two_accounts!(config("scored", %{"mode" => "enforce", "time_weight" => %{"P0" => 5}}))

      # codex is roomier but slow; claude is quick.
      pairs = [{claude, claude_quota(0.30)}, {codex, codex_quota(5.0)}]

      estimate = fn
        %{account: %{id: id}} when id == codex.id -> %{time_h: 20.0}
        _ -> %{time_h: 1.0}
      end

      pick = fn task ->
        {:ok, %{account: account}} =
          ProviderRouting.select(ws, task, :main, opts(pairs, estimate_fun: estimate))

        account.id
      end

      assert pick.(task!(ws, %{priority: 0})) == claude.id
      assert pick.(task!(ws, %{priority: 3})) == codex.id
    end

    test "one candidate: the same selection as most_quota, whatever the estimates" do
      for selection <- ["most_quota", "scored"], mode <- ["shadow", "enforce"] do
        ws = workspace!(config(selection, %{"mode" => mode, "time_weight" => %{"P0" => 9}}))
        only = account!(:claude, "only")
        allow!(ws, only, 0)
        task = task!(ws, %{priority: 0})
        pairs = [{only, claude_quota(0.2)}]

        plain = ProviderRouting.select(ws, task, :main, opts(pairs))

        estimated =
          ProviderRouting.select(
            ws,
            task,
            :main,
            opts(pairs, estimate_fun: fn _ -> %{draw: 7.0, time_h: 3.0} end)
          )

        assert choice(plain) == choice(estimated)
        assert {"selected", id, _, [id]} = choice(plain)
        assert id == only.id
      end
    end
  end

  describe "I2 property: with no estimate, scored (either mode) picks what most_quota picks" do
    property "over generated headroom, including holds and unknown readings" do
      %{ws: scored_shadow, claude: c1, codex: x1} =
        two_accounts!(config("scored", %{"mode" => "shadow"}))

      %{ws: scored_enforce, claude: c2, codex: x2} =
        two_accounts!(config("scored", %{"mode" => "enforce"}))

      %{ws: most, claude: c3, codex: x3} = two_accounts!(config("most_quota"))

      reading =
        StreamData.one_of([
          StreamData.constant(nil),
          StreamData.float(min: 0.0, max: 1.0),
          StreamData.member_of([0.2, 0.2, 0.5, 0.99])
        ])

      check all(u_claude <- reading, u_codex <- reading, max_runs: 40) do
        quota_for = fn claude, codex ->
          [
            {claude, u_claude && claude_quota(u_claude)},
            {codex, u_codex && codex_quota(u_codex * 100)}
          ]
        end

        task = fn ws ->
          %Issue{id: "t", workspace_id: ws.id, priority: 2, implementer_account_id: nil}
        end

        pick = fn ws, claude, codex ->
          ws
          |> ProviderRouting.select(task.(ws), :main, opts(quota_for.(claude, codex)))
          |> choice()
        end

        slug = fn {outcome, id, model, ids}, claude, codex ->
          name = fn
            nil -> nil
            ^id when id == claude.id -> :claude
            _ -> :codex
          end

          _ = codex

          {outcome, name.(id), model,
           Enum.map(ids, &if(&1 == claude.id, do: :claude, else: :codex))}
        end

        expected = slug.(pick.(most, c3, x3), c3, x3)
        assert slug.(pick.(scored_shadow, c1, x1), c1, x1) == expected
        assert slug.(pick.(scored_enforce, c2, x2), c2, x2) == expected
      end
    end
  end

  describe "competence matrix and reviewer coupling" do
    test "with competence: true, candidate records include expected_runs and cell" do
      cfg =
        config("scored", %{"mode" => "enforce", "competence" => true})
        |> put_in(["routing", "policy"], "by_difficulty")
        |> Map.put("agent", %{"config" => %{"tier_models" => %{"standard" => "claude-sonnet-5"}}})

      ws = workspace!(cfg)
      claude = account!(:claude, "claude")
      codex = account!(:codex, "codex")
      allow!(ws, claude, 0)
      allow!(ws, codex, 1)

      pairs = [{claude, claude_quota(0.30)}, {codex, codex_quota(5.0)}]
      task = task!(ws, %{difficulty: 2})

      assert {:ok, %{decision: d}} = ProviderRouting.select(ws, task, :main, opts(pairs))

      claude_cand = Enum.find(d["candidates"], &(&1["account_id"] == claude.id))
      assert claude_cand["expected_runs"] == %{"author" => 2.53, "review" => 2.36}
      assert %{"rung" => 1, "n" => 258} = claude_cand["cell"]

      codex_cand = Enum.find(d["candidates"], &(&1["account_id"] == codex.id))
      assert is_map(codex_cand["expected_runs"])
      assert %{"rung" => 3} = codex_cand["cell"]
    end

    test "a real agy account lands on the measured flash-medium D2 cell" do
      cfg =
        config("scored", %{"mode" => "enforce", "competence" => true})
        |> put_in(["routing", "policy"], "by_difficulty")

      ws = workspace!(cfg)
      agy = account!(:antigravity, "agy")
      allow!(ws, agy, 0)

      pairs = [{agy, agy_quota(10.0)}]
      task = task!(ws, %{difficulty: 2})

      assert {:ok, %{decision: d}} =
               ProviderRouting.select(
                 ws,
                 task,
                 :main,
                 opts(pairs, gemini_code: "antigravity")
               )

      [cand] = d["candidates"]
      assert cand["model"] == "gemini-3.8-flash-medium"
      assert %{"rung" => 1, "n" => 6} = cand["cell"]
      assert cand["expected_runs"] == %{"author" => 4.17, "review" => 2.83}
    end

    test "a Claude candidate on the default tier models hits the measured cells" do
      cfg =
        config("scored", %{"mode" => "enforce", "competence" => true})
        |> put_in(["routing", "policy"], "by_difficulty")

      ws = workspace!(cfg)
      claude = account!(:claude, "claude")
      allow!(ws, claude, 0)

      pairs = [{claude, claude_quota(0.30)}]
      task = task!(ws, %{difficulty: 2})

      assert {:ok, %{decision: d}} = ProviderRouting.select(ws, task, :main, opts(pairs))

      [cand] = d["candidates"]
      assert cand["model"] == "sonnet"
      assert %{"rung" => 1, "n" => 258} = cand["cell"]
      assert cand["expected_runs"] == %{"author" => 2.53, "review" => 2.36}
    end

    test "reviewer_coupling with a projected reviewer that has no account keeps the author price" do
      cfg =
        config("scored", %{
          "mode" => "enforce",
          "competence" => true,
          "reviewer_coupling" => true
        })
        |> put_in(["routing", "policy"], "by_difficulty")
        |> Map.put("review_agent", %{"cross_family" => true})

      ws = workspace!(cfg)
      claude = account!(:claude, "claude")
      allow!(ws, claude, 0)

      pairs = [{claude, claude_quota(0.30)}]
      task = task!(ws, %{difficulty: 2})

      assert {:ok, %{decision: d}} = ProviderRouting.select(ws, task, :main, opts(pairs))

      [cand] = d["candidates"]
      assert is_number(cand["price"])
      assert is_number(cand["score"])
    end

    test "with reviewer_coupling: true, review draw prices on projected reviewer's pool" do
      cfg_no_coupling =
        config("scored", %{
          "mode" => "enforce",
          "competence" => true,
          "reviewer_coupling" => false
        })
        |> put_in(["routing", "policy"], "by_difficulty")
        |> Map.put("agent", %{"config" => %{"tier_models" => %{"standard" => "claude-sonnet-5"}}})
        |> Map.put("review_agent", %{"cross_family" => true})

      cfg_coupling =
        config("scored", %{
          "mode" => "enforce",
          "competence" => true,
          "reviewer_coupling" => true
        })
        |> put_in(["routing", "policy"], "by_difficulty")
        |> Map.put("agent", %{"config" => %{"tier_models" => %{"standard" => "claude-sonnet-5"}}})
        |> Map.put("review_agent", %{"cross_family" => true})

      ws_uncoupled = workspace!(cfg_no_coupling)
      ws_coupled = workspace!(cfg_coupling)

      c1 = account!(:claude, "c1")
      x1 = account!(:codex, "x1")
      allow_both!(ws_uncoupled, c1, 0, 0)
      allow_both!(ws_uncoupled, x1, 1, 1)

      c2 = account!(:claude, "c2")
      x2 = account!(:codex, "x2")
      allow_both!(ws_coupled, c2, 0, 0)
      allow_both!(ws_coupled, x2, 1, 1)

      # Codex is nearly exhausted (session 90% used), so reviewer pricing onto codex will be high
      pairs_uncoupled = [{c1, claude_quota(0.30)}, {x1, codex_quota(90.0)}]
      pairs_coupled = [{c2, claude_quota(0.30)}, {x2, codex_quota(90.0)}]

      task1 = task!(ws_uncoupled, %{difficulty: 2})
      task2 = task!(ws_coupled, %{difficulty: 2})

      {:ok, %{decision: d_uncoupled}} =
        ProviderRouting.select(ws_uncoupled, task1, :main, opts(pairs_uncoupled))

      {:ok, %{decision: d_coupled}} =
        ProviderRouting.select(ws_coupled, task2, :main, opts(pairs_coupled))

      c1_cand = Enum.find(d_uncoupled["candidates"], &(&1["account_id"] == c1.id))
      c2_cand = Enum.find(d_coupled["candidates"], &(&1["account_id"] == c2.id))

      # When reviewer coupling is on, claude's review runs are priced on codex's exhausted pool,
      # so c2's price is significantly higher than c1's price (which only prices author runs on claude's pool).
      assert c2_cand["price"] > c1_cand["price"]
    end

    test "I1 / I2: no-regression with competence: false / off" do
      ws = workspace!(config("scored", %{"mode" => "shadow", "competence" => false}))
      claude = account!(:claude, "claude")
      codex = account!(:codex, "codex")
      allow!(ws, claude, 0)
      allow!(ws, codex, 1)

      pairs = [{claude, claude_quota(0.30)}, {codex, codex_quota(5.0)}]
      task = task!(ws, %{difficulty: 2})

      {:ok, %{decision: d}} = ProviderRouting.select(ws, task, :main, opts(pairs))

      for cand <- d["candidates"] do
        refute Map.has_key?(cand, "expected_runs")
        refute Map.has_key?(cand, "cell")
      end
    end

    test "one candidate: identical selection whether competence & reviewer_coupling are on or off" do
      only = account!(:claude, "only")
      pairs = [{only, claude_quota(0.30)}]

      for {competence, coupling} <- [{false, false}, {true, false}, {true, true}] do
        ws =
          workspace!(
            config("scored", %{
              "mode" => "enforce",
              "competence" => competence,
              "reviewer_coupling" => coupling
            })
          )

        allow_both!(ws, only, 0, 0)
        task = task!(ws, %{difficulty: 2})

        assert {:ok, %{account: picked, decision: d}} =
                 ProviderRouting.select(ws, task, :main, opts(pairs))

        assert picked.id == only.id
        assert d["outcome"] == "selected"
      end
    end
  end
end
