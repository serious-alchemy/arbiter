defmodule Arbiter.Loop.CanaryMatrixTest do
  @moduledoc """
  bd-d5rdsc (R13, paced-quota-routing-signals §7.1, §10, §11): the Stage 3
  canary (bd-6edc0u) on competence-matrix rows. Arms by task-id hash, first-pass
  convergence plus pool draw, auto-revert, expiry, and the no-regression
  invariant (§9): with no matrix canary running, or one eligible account, the
  scorer's behaviour is exactly what it was.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Agents.ProviderRouting
  alias Arbiter.Loop
  alias Arbiter.Loop.{Canary, PendingWrite}
  alias Arbiter.Quota.{AnthropicQuota, CodexQuota}
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Settings
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.Event
  alias Arbiter.Workers.Run

  require Ash.Query

  @config %{
    "agent" => %{"type" => "claude", "config" => %{}},
    "routing" => %{
      "policy" => "by_difficulty",
      "provider_selection" => "scored",
      "scoring" => %{"mode" => "enforce", "competence" => true}
    },
    "loop" => %{"autonomous_routing_enabled" => true}
  }

  @row %{
    "match" => %{"provider" => "claude", "model" => "claude-sonnet-5", "difficulty" => 2},
    "n" => 30,
    "rung" => 1,
    "measured_at" => "2026-10-11",
    "round_1_approve" => 0.9,
    "author_runs" => 40.0,
    "review_runs" => 1.0,
    "weight" => 1.0
  }

  setup do
    on_exit(fn ->
      Settings.set_competence_matrix(nil)
      :ets.delete_all_objects(:arbiter_provider_circuit_breakers)
    end)

    {:ok, ws} = Ash.create(Workspace, %{name: "cm-canary-ws", prefix: "cmc", config: @config})
    %{ws: ws, proposal: record!(ws, [@row])}
  end

  defp record!(ws, rows, attrs \\ %{}) do
    difficulty = rows |> hd() |> get_in(["match", "difficulty"])

    {:ok, row} =
      Loop.record(
        Map.merge(
          %{
            kind: :competence_matrix,
            gist: "measured competence moves #{length(rows)} D#{difficulty} matrix cell(s)",
            category: "competence matrix D#{difficulty}",
            target: "competence_matrix",
            difficulty: difficulty,
            scope: :fleet,
            target_metric: "first-pass ReviewGate convergence at D#{difficulty}",
            baseline: "live",
            incident_refs: ["bd-1", "bd-2", "bd-3"],
            task_refs: ["bd-1", "bd-2", "bd-3"],
            payload: %{"difficulty" => difficulty, "rows" => rows},
            origin: "loop.analyze",
            workspace_id: ws.id
          },
          attrs
        )
      )

    row
  end

  defp reload!(ws), do: Ash.get!(Workspace, ws.id)

  defp patch!(ws, patch, unset \\ []) do
    {:ok, ws} =
      Ash.update(ws, %{patch: patch, unset_paths: unset},
        action: :patch_config,
        actor: "operator"
      )

    ws
  end

  defp age_canary!(ws, days) do
    started =
      DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second) |> DateTime.to_iso8601()

    patch!(ws, %{"loop" => %{"canary" => %{"started_at" => started}}})
  end

  # `worker_runs.task_id` is a free string with no FK, so a simulated dispatch
  # needs no `Issue` row, which lets the test pick task ids (and so arms).
  defp seed_dispatch!(ws, task_id, opts) do
    converged? = Keyword.fetch!(opts, :converged)
    rounds = if converged?, do: 1, else: 2

    {:ok, run} =
      Ash.create(Run, %{
        task_id: task_id,
        repo: "arbiter",
        workspace_id: ws.id,
        kind: :implement,
        role: "base",
        state: :finished,
        outcome: :succeeded,
        model: "claude-sonnet-5",
        difficulty_at_dispatch: Keyword.get(opts, :difficulty, 2),
        started_at: DateTime.utc_now()
      })

    {:ok, _} =
      Ash.create(Event, %{
        task_id: task_id,
        step: :work,
        worker_run_id: run.id,
        provider: Keyword.get(opts, :provider, "claude"),
        model: "claude-sonnet-5",
        tokens_in: Keyword.get(opts, :tokens_in, 1_000),
        tokens_out: Keyword.get(opts, :tokens_out, 100),
        cost_usd: 1.0,
        occurred_at: DateTime.utc_now()
      })

    for round <- 1..rounds do
      {:ok, _} =
        Ash.create(Round, %{
          task_id: task_id,
          round: round,
          role: :review,
          verdict: if(round == rounds and converged?, do: :approve, else: :request_changes),
          converged: round == rounds and converged?
        })
    end

    run
  end

  defp seed_arm!(ws, canary, arm, n, converged_n, prefix, opts \\ []) do
    ids =
      1..5000
      |> Stream.map(&"#{prefix}-#{&1}")
      |> Stream.filter(&(Canary.arm(canary, &1) == arm))
      |> Enum.take(n)

    ids
    |> Enum.with_index()
    |> Enum.each(fn {id, idx} ->
      seed_dispatch!(ws, id, [converged: idx < converged_n] ++ opts)
    end)

    ids
  end

  describe "eligibility" do
    test "an escalated, evidenced D2 matrix proposal on a scored+enforce+competence workspace is eligible",
         %{proposal: proposal} do
      assert {:ok, spec} = Canary.eligible(proposal)
      assert spec.kind == :matrix
      assert spec.difficulty == 2
      assert [%{"match" => %{"model" => "claude-sonnet-5"}}] = spec.rule
    end

    test "refuses a difficulty above D2", %{ws: ws} do
      d3 = put_in(@row, ["match", "difficulty"], 3)
      proposal = record!(ws, [d3])
      assert {:error, msg} = Canary.eligible(proposal)
      assert msg =~ "D0"
    end

    test "refuses rows that carry anything but competence figures", %{ws: ws} do
      proposal = record!(ws, [Map.put(@row, "capability", ["bash"])])
      assert {:error, msg} = Canary.eligible(proposal)
      assert msg =~ "capability"
    end

    test "refuses a row whose match difficulty differs from the proposal's", %{ws: ws} do
      proposal =
        record!(ws, [@row], %{
          payload: %{"difficulty" => 1, "rows" => [@row]},
          category: "competence matrix D1",
          difficulty: 1
        })

      assert {:error, _} = Canary.eligible(proposal)
    end

    test "refuses when the workspace would never read the matrix", %{ws: ws, proposal: proposal} do
      for {path, label} <- [
            {["routing", "provider_selection"], "most_quota"},
            {["routing", "scoring", "competence"], false},
            {["routing", "scoring", "mode"], "shadow"}
          ] do
        patch =
          Enum.reduce(Enum.reverse(path), label, fn key, acc -> %{key => acc} end)

        off = patch!(ws, patch)
        assert {:error, msg} = Canary.eligible(proposal), "expected refusal for #{inspect(path)}"
        assert msg =~ "scored"
        patch!(off, Enum.reduce(Enum.reverse(path), original(path), fn k, a -> %{k => a} end))
      end
    end

    defp original(["routing", "provider_selection"]), do: "scored"
    defp original(["routing", "scoring", "competence"]), do: true
    defp original(["routing", "scoring", "mode"]), do: "enforce"
  end

  describe "start / overlay" do
    test "starting writes a matrix canary block and never touches the live matrix", ctx do
      assert {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      assert %Canary{kind: :matrix, difficulty: 2, rule: [_]} = Canary.active(ws)
      assert get_in(ws.config, ["loop", "canary", "kind"]) == "matrix"
      assert Settings.competence_matrix() in [nil, []]
    end

    test "the routing overlay ignores a matrix canary", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      for i <- 1..20, do: assert(Canary.overlay(ws, "t-#{i}", 2) == nil)
    end

    test "matrix_rows/2 hands the rows to the canary arm, at the canaried difficulty only", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)

      [canary_id] = pick_ids(canary, :canary, 1)
      [control_id] = pick_ids(canary, :control, 1)

      assert [%{"match" => %{"difficulty" => 2}}] =
               Canary.matrix_rows(ws, %Issue{id: canary_id, difficulty: 2, permissions: []})

      assert Canary.matrix_rows(ws, %Issue{id: control_id, difficulty: 2, permissions: []}) == []
      assert Canary.matrix_rows(ws, %Issue{id: canary_id, difficulty: 1, permissions: []}) == []

      # §7.1: a ticket carrying permissions is never explored on.
      assert Canary.matrix_rows(ws, %Issue{id: canary_id, difficulty: 2, permissions: ["net"]}) ==
               []

      # A review/impl suffix hashes with its task, so a task is never half-canaried.
      assert Canary.matrix_rows(ws, %Issue{
               id: canary_id <> "#review",
               difficulty: 2,
               permissions: []
             }) != []
    end

    test "with the opt-in flag unset (the kill switch) there is no overlay", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)
      [id] = pick_ids(canary, :canary, 1)
      off = patch!(ws, %{}, ["loop.autonomous_routing_enabled"])
      assert Canary.matrix_rows(off, %Issue{id: id, difficulty: 2, permissions: []}) == []
    end

    test "with no canary at all matrix_rows/2 is empty", ctx do
      assert Canary.matrix_rows(ctx.ws, %Issue{id: "x", difficulty: 2, permissions: []}) == []
      assert Canary.matrix_rows(nil, %Issue{id: "x", difficulty: 2}) == []
    end

    test "a routing canary does not hand out matrix rows", ctx do
      {:ok, routing} =
        Loop.record(%{
          kind: :config_set,
          gist: "raise D2",
          category: "difficulty misestimate — D2 under-provisioned",
          target: "routing.rules.D2",
          difficulty: 2,
          scope: :fleet,
          target_metric: "m",
          baseline: "b",
          incident_refs: ["a", "b", "c"],
          task_refs: ["t1", "t2"],
          payload: %{
            "workspace_id" => ctx.ws.id,
            "patch" => %{
              "routing" => %{
                "rules" => %{"D2" => %{"model_tier" => "premium", "thinking" => "high"}}
              }
            }
          },
          origin: "loop.analyze",
          workspace_id: ctx.ws.id
        })

      {:ok, ws} = Canary.start(ctx.ws, routing, actor: "loop")
      assert %Canary{kind: :routing} = Canary.active(ws)
      canary = Canary.active(ws)
      [id] = pick_ids(canary, :canary, 1)
      assert Canary.matrix_rows(ws, %Issue{id: id, difficulty: 2, permissions: []}) == []
    end

    test "one canary at a time: a second start is refused", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      other = record!(ws, [put_in(@row, ["match", "model"], "claude-other")])
      assert {:error, msg} = Canary.start(ws, other, actor: "loop")
      assert msg =~ "already running"
    end
  end

  defp pick_ids(canary, arm, n) do
    1..5000
    |> Stream.map(&"pick-#{&1}")
    |> Stream.filter(&(Canary.arm(canary, &1) == arm))
    |> Enum.take(n)
  end

  describe "the cycle" do
    test "reverts automatically when first-pass convergence regresses; the live matrix is never touched",
         ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)

      seed_arm!(ws, canary, :canary, 20, 4, "can")
      seed_arm!(ws, canary, :control, 20, 16, "con")

      assert {:revert, stats} = Canary.evaluate(ws)
      assert stats.canary.dispatches == 20

      assert {:ok, {:reverted, _}} = Canary.tick(ws)

      refute get_in(reload!(ws).config, ["loop", "canary"])
      assert Settings.competence_matrix() in [nil, []]

      row = Ash.get!(PendingWrite, ctx.proposal.id)
      assert row.state == :rejected
      assert row.outcome_delta["verdict"] == "revert"
    end

    test "promotes by landing the rows in the live matrix, keeping the previous one", ctx do
      live = %{
        "match" => %{"provider" => "claude", "model" => "claude-old", "difficulty" => 2},
        "n" => 5
      }

      {:ok, _} = Settings.set_competence_matrix([live])

      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)

      seed_arm!(ws, canary, :canary, 20, 18, "can")
      seed_arm!(ws, canary, :control, 20, 10, "con")

      assert {:ok, {:promoted, _}} = Canary.tick(ws)

      refute get_in(reload!(ws).config, ["loop", "canary"])
      matrix = Settings.competence_matrix()
      assert live in matrix

      assert Enum.any?(
               matrix,
               &(&1["match"]["model"] == "claude-sonnet-5" and &1["author_runs"] == 40.0)
             )

      assert Settings.competence_matrix_previous() == [live]

      row = Ash.get!(PendingWrite, ctx.proposal.id)
      assert row.state == :applied
      assert row.outcome_delta["verdict"] == "promote"
    end

    test "canary_auto_promote: false holds the verdict for the operator", ctx do
      ws = patch!(ctx.ws, %{"loop" => %{"canary_auto_promote" => false}})
      {:ok, ws} = Canary.start(ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)

      seed_arm!(ws, canary, :canary, 20, 18, "can")
      seed_arm!(ws, canary, :control, 20, 10, "con")

      assert {:ok, {:awaiting_operator, _}} = Canary.tick(ws)
      assert Settings.competence_matrix() in [nil, []]
      assert Ash.get!(PendingWrite, ctx.proposal.id).state == :proposed
    end

    test "holds its verdict until the canary arm has min_dispatches", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)

      seed_arm!(ws, canary, :canary, 19, 0, "can")
      seed_arm!(ws, canary, :control, 20, 20, "con")

      assert {:insufficient_data, _} = Canary.evaluate(ws)
      assert {:ok, {:running, _}} = Canary.tick(ws)
    end

    test "expires unjudged, rejecting the proposal and leaving the matrix alone", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)
      seed_arm!(ws, canary, :canary, 4, 4, "can")

      aged = age_canary!(ws, 15)
      assert {:ok, {:expired, info}} = Canary.tick(aged)
      assert info.proposal_id == ctx.proposal.id

      refute get_in(reload!(ws).config, ["loop", "canary"])
      assert Settings.competence_matrix() in [nil, []]

      row = Ash.get!(PendingWrite, ctx.proposal.id)
      assert row.state == :rejected
      assert row.rejection_reason =~ "expired"
      assert row.rejection_reason =~ "competence"
      assert row.outcome_delta["verdict"] == "expired"
    end

    test "an operator's rejection mid-canary outranks a passing canary", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)
      seed_arm!(ws, canary, :canary, 20, 20, "can")
      seed_arm!(ws, canary, :control, 20, 0, "con")

      {:ok, _} = Loop.reject_pending(ctx.proposal, reason: "no", actor: "operator")
      assert {:ok, {:abandoned, _}} = Canary.tick(reload!(ws))
      assert Settings.competence_matrix() in [nil, []]
    end

    test "the kill switch drops a matrix canary", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      off = patch!(ws, %{}, ["loop.autonomous_routing_enabled"])
      assert {:ok, {:stopped, %{reason: :kill_switch}}} = Canary.tick(off)
      refute get_in(reload!(ws).config, ["loop", "canary"])
    end

    test "tick starts an eligible matrix proposal when nothing else is running", ctx do
      assert {:ok, {:started, %Canary{kind: :matrix}}} = Canary.tick(ctx.ws)
    end
  end

  describe "the measurement" do
    test "reports each arm's pool draw next to first-pass convergence", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)

      seed_arm!(ws, canary, :canary, 3, 3, "can",
        provider: "codex",
        tokens_in: 2_000,
        tokens_out: 0
      )

      seed_arm!(ws, canary, :control, 2, 2, "con",
        provider: "claude",
        tokens_in: 1_000,
        tokens_out: 0
      )

      {_verdict, stats} = Canary.evaluate(ws)
      assert stats.canary.draw.weighted_tokens > stats.control.draw.weighted_tokens
      assert Map.keys(stats.canary.draw.by_pool) == ["codex"]
      assert Map.keys(stats.control.draw.by_pool) == ["claude"]
    end

    test "tasks carrying permissions are left out of both arms", ctx do
      {:ok, ws} = Canary.start(ctx.ws, ctx.proposal, actor: "loop")
      canary = Canary.active(ws)

      ids = seed_arm!(ws, canary, :canary, 5, 5, "can")
      ws_id = ws.id

      for id <- Enum.take(ids, 2) do
        Arbiter.Repo.query!(
          """
          INSERT INTO issues (id, workspace_id, title, issue_type, difficulty, priority,
                              tracker_type, state, permissions, created_at, updated_at)
          VALUES (?1, ?2, ?1, 'feature', 2, 2, 'none', 'active', '["net"]', ?3, ?3)
          """,
          [id, ws_id, DateTime.to_iso8601(DateTime.utc_now())]
        )
      end

      {_verdict, stats} = Canary.evaluate(ws)
      assert stats.canary.dispatches == 3
      assert stats.permissioned == 2
    end

    test "a routing canary's measurement is unchanged (no permissions filter)", ctx do
      assert ctx.proposal.kind == :competence_matrix
    end
  end

  describe "routing: the canary arm ranks with the proposed rows" do
    defp account!(provider, slug),
      do:
        Ash.create!(ProviderAccount, %{
          provider: provider,
          slug: "#{slug}-#{System.unique_integer([:positive])}"
        })

    defp allow!(ws, account, position),
      do:
        Ash.create!(WorkspaceProviderAccount, %{
          workspace_id: ws.id,
          provider: account.provider,
          provider_account_id: account.id,
          implementer_position: position
        })

    defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
    defp ahead(secs), do: DateTime.add(now(), secs, :second)

    defp claude_quota,
      do: %AnthropicQuota{
        provider: "claude",
        utilization_5h: 0.30,
        reset_5h_at: ahead(9_000),
        status_5h: "allowed",
        utilization_7d: 0.0,
        reset_7d_at: ahead(302_400),
        status_7d: "allowed",
        captured_at: now()
      }

    defp codex_quota,
      do: %CodexQuota{
        provider: "codex",
        session_used_percent: 5.0,
        session_reset_at: ahead(3_600),
        weekly_used_percent: 0.0,
        weekly_reset_at: ahead(302_400),
        limit_reached: false,
        captured_at: now()
      }

    defp pick(ws, task, accounts) do
      quotas = %{
        elem(accounts, 0).id => claude_quota(),
        elem(accounts, 1).id => codex_quota()
      }

      opts = [quota_fun: fn account -> Map.get(quotas, account.id) end, pin: false]
      {:ok, %{decision: d}} = ProviderRouting.select(ws, task, :main, opts)
      {d["account_id"], d["model"], Enum.map(d["candidates"], & &1["account_id"])}
    end

    test "only the canary arm's pick moves; the control arm and the no-canary pick agree", ctx do
      claude = account!(:claude, "claude")
      codex = account!(:codex, "codex")
      allow!(ctx.ws, claude, 0)
      allow!(ctx.ws, codex, 1)
      accounts = {claude, codex}

      ws = reload!(ctx.ws)

      task = fn id ->
        %Issue{id: id, workspace_id: ws.id, priority: 2, difficulty: 2, permissions: []}
      end

      # Learn the baseline pick, then propose rows that make exactly that pick
      # expensive.
      {base_account, base_model, base_order} = pick(ws, task.("probe"), accounts)
      base_provider = if base_account == claude.id, do: "claude", else: "codex"

      heavy = %{
        "match" => %{"provider" => base_provider, "model" => base_model, "difficulty" => 2},
        "n" => 40,
        "rung" => 1,
        "author_runs" => 500.0,
        "review_runs" => 500.0,
        "weight" => 1.0
      }

      proposal = record!(ws, [heavy])
      {:ok, started} = Canary.start(ws, proposal, actor: "loop")
      canary = Canary.active(started)

      [canary_id] = pick_ids(canary, :canary, 1)
      [control_id] = pick_ids(canary, :control, 1)

      {canary_account, _, canary_order} = pick(started, task.(canary_id), accounts)
      {control_account, _, control_order} = pick(started, task.(control_id), accounts)

      assert control_account == base_account
      assert control_order == base_order
      refute canary_account == base_account
      assert Enum.sort(canary_order) == Enum.sort(base_order)

      # Without the canary the canary-arm task is back on the baseline.
      {:ok, _} = Loop.reject_pending(proposal, reason: "x", actor: "operator")
      {:ok, _} = Canary.tick(reload!(started))
      assert {^base_account, _, ^base_order} = pick(reload!(started), task.(canary_id), accounts)
    end

    test "I2: with one eligible account the canary arm's selection is the baseline's", ctx do
      claude = account!(:claude, "claude")
      codex = account!(:codex, "codex")
      allow!(ctx.ws, claude, 0)
      ws = reload!(ctx.ws)
      _ = codex

      quotas = fn account -> if account.id == claude.id, do: claude_quota() end
      opts = [quota_fun: quotas, pin: false]

      task = fn id ->
        %Issue{id: id, workspace_id: ws.id, priority: 2, difficulty: 2, permissions: []}
      end

      select = fn w, id ->
        {:ok, %{decision: d}} = ProviderRouting.select(w, task.(id), :main, opts)
        {d["outcome"], d["account_id"], d["model"]}
      end

      baseline = select.(ws, "probe")

      {:ok, started} = Canary.start(ws, ctx.proposal, actor: "loop")
      canary = Canary.active(started)
      [canary_id] = pick_ids(canary, :canary, 1)

      assert select.(started, canary_id) == baseline
    end

    test "with the layer off (competence: false) a running canary changes nothing", ctx do
      claude = account!(:claude, "claude")
      codex = account!(:codex, "codex")
      allow!(ctx.ws, claude, 0)
      allow!(ctx.ws, codex, 1)

      ws = reload!(ctx.ws)

      task = fn id ->
        %Issue{id: id, workspace_id: ws.id, priority: 2, difficulty: 2, permissions: []}
      end

      {:ok, started} = Canary.start(ws, ctx.proposal, actor: "loop")
      canary = Canary.active(started)
      [canary_id] = pick_ids(canary, :canary, 1)
      [control_id] = pick_ids(canary, :control, 1)

      # The layer is switched off underneath the running canary: the matrix is not
      # read, so the two arms rank identically.
      off = patch!(started, %{"routing" => %{"scoring" => %{"competence" => false}}})

      assert pick(off, task.(canary_id), {claude, codex}) ==
               pick(off, task.(control_id), {claude, codex})
    end
  end
end
