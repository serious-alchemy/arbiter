defmodule Arbiter.Loop.OperatorCanaryTest do
  @moduledoc """
  An operator-started, report-only routing canary: `Loop.propose_routing/1`,
  `loop.canary_auto_promote: false`, and `Canary.status/1`.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Loop
  alias Arbiter.Loop.{Canary, PendingWrite}
  alias Arbiter.Messages.Message
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event
  alias Arbiter.Workers.Run

  @routing_config %{
    "agent" => %{"type" => "claude", "config" => %{}},
    "routing" => %{"policy" => "by_difficulty"}
  }

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "operator-canary-ws", prefix: "oc", config: @routing_config})

    ws = patch!(ws, %{"loop" => %{"autonomous_routing_enabled" => true}})
    %{ws: ws}
  end

  defp patch!(ws, patch, unset \\ []) do
    {:ok, ws} =
      Ash.update(ws, %{patch: patch, unset_paths: unset}, action: :patch_config, actor: "test")

    ws
  end

  defp propose!(ws, attrs \\ %{}) do
    {:ok, row} =
      Loop.propose_routing(
        Map.merge(
          %{workspace: ws.id, difficulty: 3, model_tier: "standard", thinking: "high"},
          attrs
        )
      )

    row
  end

  defp verdict_mail do
    Message
    |> Ash.read!()
    |> Enum.filter(&(&1.escalation_kind == :loop_canary and &1.subject =~ "verdict ready"))
  end

  # ---- seeding ------------------------------------------------------------

  # `worker_runs.task_id` is a free string with no FK, and the canary reads the
  # dispatched tier off `difficulty_at_dispatch`, so a simulated dispatch needs
  # no `Issue` row — which is what lets the test choose task ids and therefore
  # arms deterministically (`Issue` ids are generated, not accepted).
  defp seed_dispatch!(ws, task_id, opts) do
    difficulty = Keyword.get(opts, :difficulty, 3)
    converged? = Keyword.fetch!(opts, :converged)
    rounds = if converged?, do: 1, else: Keyword.get(opts, :rounds, 2)

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
        difficulty_at_dispatch: difficulty,
        started_at: DateTime.utc_now()
      })

    {:ok, _} =
      Ash.create(Event, %{
        task_id: task_id,
        step: :work,
        worker_run_id: run.id,
        cost_usd: Keyword.get(opts, :cost, 1.0),
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

  # Seed `n` dispatches into the given arm, `converged_n` of which converge on
  # the first review round. Task ids are drawn from a wide pool and filtered by
  # the canary's own arm function, so the seeded data lands in the arm the
  # routing overlay would actually have placed it in.
  defp seed_arm!(ws, canary, arm, n, converged_n, prefix) do
    ids =
      1..5000
      |> Stream.map(&"#{prefix}-#{&1}")
      |> Stream.filter(&(Canary.arm(canary, &1) == arm))
      |> Enum.take(n)

    assert length(ids) == n

    ids
    |> Enum.with_index()
    |> Enum.each(fn {id, idx} ->
      seed_dispatch!(ws, id, converged: idx < converged_n)
    end)

    ids
  end

  defp reload!(ws), do: Ash.get!(Workspace, ws.id)

  describe "Loop.propose_routing/1" do
    test "creates an operator-authored proposal that a tick starts a canary for", %{ws: ws} do
      row = propose!(ws)

      assert row.state == :proposed
      assert row.kind == :config_set
      assert row.escalated_at
      assert row.origin == Canary.operator_origin()

      assert row.payload["patch"] == %{
               "routing" => %{
                 "rules" => %{"D3" => %{"model_tier" => "standard", "thinking" => "high"}}
               }
             }

      assert {:ok, {:started, canary}} = Canary.tick(ws)
      assert canary.proposal_id == row.id
      assert canary.difficulty == 3
      assert canary.rule == %{"model_tier" => "standard", "thinking" => "high"}
    end

    test "accepts a workspace name and omits thinking when not given", %{ws: ws} do
      row = propose!(ws, %{workspace: ws.name, thinking: nil})
      assert row.payload["patch"]["routing"]["rules"]["D3"] == %{"model_tier" => "standard"}
    end

    test "rejects a bad difficulty, a missing tier and an unknown workspace", %{ws: ws} do
      assert {:error, {:invalid, _}} =
               Loop.propose_routing(%{workspace: ws.id, difficulty: 9, model_tier: "standard"})

      assert {:error, {:invalid, _}} = Loop.propose_routing(%{workspace: ws.id, difficulty: 3})

      assert {:error, {:not_found, _}} =
               Loop.propose_routing(%{workspace: "nope", difficulty: 3, model_tier: "standard"})
    end

    test "a second identical proposal does not duplicate a live one", %{ws: ws} do
      row = propose!(ws)

      assert {:ok, again} =
               Loop.propose_routing(%{
                 workspace: ws.id,
                 difficulty: 3,
                 model_tier: "standard",
                 thinking: "high"
               })

      assert again.id == row.id
    end

    test "an identical proposal that was rejected is refused, not silently reopened", %{ws: ws} do
      row = propose!(ws)
      {:ok, _} = Loop.reject_pending(row, reason: "no", actor: "operator")

      assert {:error, {:invalid, message}} =
               Loop.propose_routing(%{
                 workspace: ws.id,
                 difficulty: 3,
                 model_tier: "standard",
                 thinking: "high"
               })

      assert message =~ row.id
    end
  end

  describe "loop.canary_auto_promote: false" do
    setup %{ws: ws} do
      ws = patch!(ws, %{"loop" => %{"canary_auto_promote" => false}})
      proposal = propose!(ws)
      {:ok, {:started, canary}} = Canary.tick(ws)
      ws = reload!(ws)
      seed_arm!(ws, canary, :canary, 20, 18, "can")
      seed_arm!(ws, canary, :control, 20, 10, "con")
      %{ws: ws, canary: canary, proposal: proposal}
    end

    test "a promote verdict leaves routing.rules alone, keeps the proposal, mails once",
         %{ws: ws, proposal: proposal} do
      assert {:promote, _} = Canary.evaluate(ws)
      assert {:ok, {:awaiting_operator, stats}} = Canary.tick(ws)
      assert stats.canary.dispatches == 20

      held = reload!(ws)
      refute get_in(held.config, ["routing", "rules", "D3"])
      assert get_in(held.config, ["loop", "canary", "proposal_id"]) == proposal.id
      assert Ash.get!(PendingWrite, proposal.id).state == :proposed
      assert [mail] = verdict_mail()
      assert mail.body =~ "arb loop apply #{proposal.id}"
      assert mail.body =~ "90.0%"

      # The 15-minute ticker must not repeat itself.
      assert {:ok, {:awaiting_operator, _}} = Canary.tick(held)
      assert length(verdict_mail()) == 1
    end

    test "the operator then applies it, and the canary is abandoned", %{
      ws: ws,
      proposal: proposal
    } do
      {:ok, {:awaiting_operator, _}} = Canary.tick(ws)
      {:ok, _} = Loop.apply_pending(Ash.get!(PendingWrite, proposal.id), actor: "operator")

      applied = reload!(ws)

      assert get_in(applied.config, ["routing", "rules", "D3"]) ==
               %{"model_tier" => "standard", "thinking" => "high"}

      assert {:ok, {:abandoned, _}} = Canary.tick(applied)
      refute get_in(reload!(ws).config, ["loop", "canary"])
    end

    test "a revert verdict is still automatic", %{ws: ws, canary: canary, proposal: proposal} do
      seed_arm!(ws, canary, :canary, 40, 0, "bad")
      seed_arm!(ws, canary, :control, 40, 40, "good")

      assert {:revert, _} = Canary.evaluate(ws)
      assert {:ok, {:reverted, _}} = Canary.tick(ws)
      refute get_in(reload!(ws).config, ["loop", "canary"])
      assert Ash.get!(PendingWrite, proposal.id).state == :rejected
    end
  end

  describe "loop.canary_auto_promote unset or true" do
    for setting <- [:unset, true] do
      test "a promote verdict still lands the rule (#{inspect(setting)})", %{ws: ws} do
        ws =
          if unquote(setting) == true,
            do: patch!(ws, %{"loop" => %{"canary_auto_promote" => true}}),
            else: ws

        proposal = propose!(ws)
        {:ok, {:started, canary}} = Canary.tick(ws)
        ws = reload!(ws)
        seed_arm!(ws, canary, :canary, 20, 18, "can")
        seed_arm!(ws, canary, :control, 20, 10, "con")

        assert {:ok, {:promoted, _}} = Canary.tick(ws)

        assert get_in(reload!(ws).config, ["routing", "rules", "D3"]) ==
                 %{"model_tier" => "standard", "thinking" => "high"}

        assert Ash.get!(PendingWrite, proposal.id).state == :applied
        assert verdict_mail() == []
      end
    end

    test "a revert verdict drops the block", %{ws: ws} do
      proposal = propose!(ws)
      {:ok, {:started, canary}} = Canary.tick(ws)
      ws = reload!(ws)
      seed_arm!(ws, canary, :canary, 20, 0, "can")
      seed_arm!(ws, canary, :control, 20, 20, "con")

      assert {:ok, {:reverted, _}} = Canary.tick(ws)
      refute get_in(reload!(ws).config, ["loop", "canary"])
      assert Ash.get!(PendingWrite, proposal.id).state == :rejected
    end
  end

  describe "Canary.status/1" do
    test "says why when there is no canary", %{ws: ws} do
      assert {:none, message} = Canary.status(ws)
      assert message =~ "no canary is running"

      off = patch!(ws, %{}, ["loop.autonomous_routing_enabled"])
      assert {:none, message} = Canary.status(off)
      assert message =~ "autonomous_routing_enabled"
    end

    test "reports both arms and verdict progress for a running canary", %{ws: ws} do
      proposal = propose!(ws)
      {:ok, {:started, canary}} = Canary.tick(ws)
      ws = reload!(ws)
      seed_arm!(ws, canary, :canary, 5, 4, "can")
      seed_arm!(ws, canary, :control, 6, 3, "con")

      assert {:ok, status} = Canary.status(ws)
      assert status.proposal_id == proposal.id
      assert status.proposal_state == :proposed
      assert status.difficulty == 3
      assert status.dispatches_left == 15
      assert status.verdict == :insufficient_data
      assert status.auto_promote
      assert status.canary.dispatches == 5
      assert status.canary.reviewed_tasks == 5
      assert_in_delta status.canary.first_pass_convergence, 0.8, 0.001
      assert status.control.dispatches == 6
      assert_in_delta status.control.first_pass_convergence, 0.5, 0.001
      assert status.canary.cost_usd == 5.0
      assert status.age_days >= 0
      assert %DateTime{} = status.expires_at
    end
  end
end

defmodule Arbiter.Loop.OperatorCanaryMcpTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.{Catalog, Scope}
  alias Arbiter.Tasks.Workspace

  test "loop_propose_routing and loop_canary_status are coordinator tools over the same flow" do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "mcp-canary-ws",
        prefix: "mc",
        config: %{"routing" => %{"policy" => "by_difficulty"}}
      })

    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}

    assert {:ok, row} =
             Catalog.call(coordinator, "loop_propose_routing", %{
               "difficulty" => 3,
               "model_tier" => "standard",
               "thinking" => "high"
             })

    assert row.state == :proposed
    assert row.proposed

    assert {:ok, %{running: false, message: message}} =
             Catalog.call(coordinator, "loop_canary_status", %{})

    assert message =~ "no canary is running"

    worker = %Scope{tier: :worker, workspace_id: ws.id, task_id: "t", repo: "r"}
    assert {:rpc_error, -32_003, _} = Catalog.call(worker, "loop_canary_status", %{})
  end
end
