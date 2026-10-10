defmodule Arbiter.Loop.TrustPromotionTest do
  @moduledoc """
  G18 (bd-7i9pxn, `docs/design/guardrail-profiles.md` §6.3–6.4): the Loop
  *proposes* a promotion as an operator-only `trust_promotion` PendingWrite;
  `Arbiter.Loop.apply_pending/2` (behind `arb loop apply` and MCP
  `loop_pending_apply`) refuses it at any authority, and only
  `Arbiter.Loop.Trust.promote/4` with operator authority applies it.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.TrustFixtures

  alias Arbiter.Guardrails
  alias Arbiter.Guardrails.Rules
  alias Arbiter.Loop
  alias Arbiter.Loop.PendingWrite
  alias Arbiter.Loop.Trust
  alias Arbiter.Messages.Message

  require Ash.Query

  @codex {"codex", "gpt-5.1-codex"}
  @opus {"claude", "claude-opus-4-6"}

  setup do
    %{ws: workspace!()}
  end

  # Ten clean D1 runs of codex on ten tickets, all approved in round 1, and an
  # incumbent (claude, privileged) with ten reviewed D1 tickets at 90%: codex is
  # 10 points *above* it, so every §6.3 quarantine → probation threshold holds.
  defp eligible!(ws, opts \\ []) do
    rule!(Map.merge(%{provider: "codex", tier: :quarantine}, Map.new(opts)))
    rule!(%{provider: "claude", tier: :privileged})

    runs =
      for i <- 1..10 do
        task!(ws, "q#{i}", @codex, at: DateTime.add(~U[2026-09-20 10:00:00Z], i * 86_400))
      end

    for i <- 1..10 do
      task!(ws, "c#{i}", @opus,
        at: DateTime.add(~U[2026-09-20 12:00:00Z], i * 86_400),
        round1: i != 10
      )
    end

    runs
  end

  defp tick!, do: Trust.tick(now: now(), cutover: cutover(), workers: [])

  defp proposals do
    Loop.list_pending(kind: :trust_promotion)
  end

  defp rule_tier({provider, model}) do
    case Rules.match(Rules.all(), Guardrails.subject(provider, model)) do
      nil -> :quarantine
      rule -> rule.tier
    end
  end

  describe "the proposal" do
    test "is emitted when the §6.3 thresholds are met, with the clean runs as its evidence", %{
      ws: ws
    } do
      runs = eligible!(ws)
      {:ok, _} = tick!()

      assert %{eligible_for: :probation} = Trust.get(@codex)

      assert [%PendingWrite{} = row] = proposals()
      assert row.state == :proposed
      assert row.target == "codex/gpt-5.1-codex"
      assert Enum.sort(row.incident_refs) == Enum.sort(runs)
      assert length(row.task_refs) == 10

      assert %{"provider" => "codex", "model" => "gpt-5.1-codex", "from" => "quarantine"} =
               row.payload

      assert row.payload["to"] == "probation"

      # The coordinator hears of it, pointed at the operator's command.
      [page] =
        Message
        |> Ash.Query.filter(escalation_kind == :loop_proposal)
        |> Ash.read!()

      assert page.body =~ "arb trust promote codex/gpt-5.1-codex --to probation"
      refute page.body =~ "arb loop apply"

      # A second tick reinforces the same row.
      {:ok, _} = Trust.tick(now: DateTime.add(now(), 900), cutover: cutover(), workers: [])
      assert [%{id: id}] = proposals()
      assert id == row.id
    end

    # `Loop.record/2` attributes a fleet candidate with no workspace to the
    # install default, and refuses when that is ambiguous (several workspaces,
    # none named "default"). A proposal names the workspace its newest clean run
    # worked in instead, so it is emitted on any install.
    test "is emitted on an install with several workspaces, in its newest clean run's", %{
      ws: ws
    } do
      other = workspace!()
      eligible!(ws)
      task!(other, "q11", @codex, at: ~U[2026-10-09 10:00:00Z])

      {:ok, _} = tick!()

      assert [%PendingWrite{state: :proposed} = row] = proposals()
      assert row.workspace_id == other.id
      assert length(row.incident_refs) == 11

      assert [page] =
               Message
               |> Ash.Query.filter(escalation_kind == :loop_proposal)
               |> Ash.read!()

      assert page.workspace_id == other.id
    end

    test "is never emitted for a pinned subject", %{ws: ws} do
      eligible!(ws, pinned: true)
      {:ok, _} = tick!()

      assert %{eligible_for: nil, eligibility: %{"blocked_by" => "pinned"}} = Trust.get(@codex)
      assert proposals() == []
    end

    test "is never emitted for trusted → privileged", %{ws: ws} do
      eligible!(ws)
      rule!(%{provider: "codex", tier: :trusted})
      {:ok, _} = tick!()

      assert %{eligible_for: nil, eligibility: %{"to" => "privileged", "proposed" => false}} =
               Trust.get(@codex)

      assert proposals() == []
    end

    test "is superseded when the subject stops being eligible", %{ws: ws} do
      [run | _] = eligible!(ws)
      {:ok, _} = tick!()
      assert [%{state: :proposed}] = proposals()

      event!(run, "q1", @codex, :credential_read, :major, ~U[2026-10-10 12:30:00Z])
      {:ok, _} = Trust.tick(now: DateTime.add(now(), 3600), cutover: cutover(), workers: [])

      assert [%{state: :superseded}] = proposals()
    end

    test "arb loop apply and loop_pending_apply refuse it, at any authority", %{ws: ws} do
      eligible!(ws)
      {:ok, _} = tick!()
      [row] = proposals()

      for authority <- [:operator, :coordinator] do
        assert {:error, {:not_applicable, why}} =
                 Loop.apply_pending(row, authority: authority, actor: "operator")

        assert why =~ "operator-only"
        assert why =~ "arb trust promote"
      end

      refute Loop.applicable?(row)
      # Its payload is complete: it is operator-only, not unauthored.
      assert Loop.authoring_gap(row) == nil
      assert rule_tier(@codex) == :quarantine
      assert [%{state: :proposed}] = proposals()
    end
  end

  describe "the view (arb trust show, trust_show, /trust)" do
    test "a subject's tier, record, recent events and pending proposal", %{ws: ws} do
      [run | _] = eligible!(ws)
      event!(run, "q1", @codex, :permission_denial, :minor, ~U[2026-10-01 12:00:00Z])
      {:ok, _} = tick!()
      [row] = proposals()

      assert {:ok, detail} = Arbiter.Loop.Trust.View.detail("codex/gpt-5.1-codex")

      assert detail.subject == "codex/gpt-5.1-codex"
      assert detail.tier == "quarantine"
      assert detail.effective_tier == "quarantine"
      assert detail.suspended == nil
      assert detail.record.clean_runs == 10
      assert detail.record.minor_events == 1
      assert detail.eligibility.eligible_for == "probation"
      assert [%{"kind" => "permission_denial"}] = detail.recent_events
      assert [%{id: id, to: "probation", state: "proposed"}] = detail.pending
      assert id == row.id

      assert {:error, :not_found} = Arbiter.Loop.Trust.View.detail("codex/nope")
    end

    test "a suspended subject shows quarantine as its effective tier, and the list says so", %{
      ws: ws
    } do
      [run | _] = eligible!(ws)
      rule!(%{provider: "codex", tier: :probation})
      event!(run, "q1", @codex, :public_upload_attempt, :critical, ~U[2026-10-10 11:00:00Z])
      {:ok, _} = tick!()

      summaries = Arbiter.Loop.Trust.View.list()
      codex = Enum.find(summaries, &(&1.subject == "codex/gpt-5.1-codex"))

      assert codex.tier == "probation"
      assert codex.effective_tier == "quarantine"
      assert %{kind: "public_upload_attempt"} = codex.suspended
      assert Enum.find(summaries, &(&1.subject == "claude/claude-opus-4-6")).tier == "privileged"
    end
  end

  describe "promote/4" do
    test "applies the proposal with operator authority and records actor operator", %{ws: ws} do
      eligible!(ws)
      {:ok, _} = tick!()
      [row] = proposals()

      assert {:ok, %{record: record, proposal: applied}} =
               Trust.promote("codex/gpt-5.1-codex", "probation", "ten clean D1 runs",
                 authority: :operator
               )

      assert rule_tier(@codex) == :probation
      assert record.tier == :probation
      assert applied.id == row.id
      assert applied.state == :applied
      assert applied.actor == "operator"

      assert %{"action" => "promoted", "actor" => "operator", "to" => "probation"} =
               List.last(record.history)

      assert List.last(record.history)["reason"] == "ten clean D1 runs"
    end

    test "refuses any authority but the operator's, and changes nothing", %{ws: ws} do
      eligible!(ws)
      {:ok, _} = tick!()

      for authority <- [:coordinator, :restricted] do
        assert {:error, {:operator_only, _}} =
                 Trust.promote("codex/gpt-5.1-codex", "probation", "because",
                   authority: authority
                 )
      end

      assert rule_tier(@codex) == :quarantine
      assert [%{state: :proposed}] = proposals()
    end

    test "needs a reason, a real tier, and a move up", %{ws: ws} do
      eligible!(ws)
      {:ok, _} = tick!()

      assert {:error, {:invalid, _}} =
               Trust.promote("codex/gpt-5.1-codex", "probation", "  ", authority: :operator)

      assert {:error, {:invalid, _}} =
               Trust.promote("codex/gpt-5.1-codex", "godlike", "why", authority: :operator)

      assert {:error, {:invalid, why}} =
               Trust.promote("codex/gpt-5.1-codex", "quarantine", "why", authority: :operator)

      assert why =~ "not a promotion"
    end

    test "with no proposal the operator may still set a tier: privileged is never proposed", %{
      ws: ws
    } do
      rule!(%{provider: "codex", tier: :trusted})
      task!(ws, "p1", @codex, at: ~U[2026-10-01 10:00:00Z])
      {:ok, _} = tick!()

      assert {:ok, %{proposal: nil, record: %{tier: :privileged}}} =
               Trust.promote("codex/gpt-5.1-codex", "privileged", "prod work, reviewed",
                 authority: :operator
               )

      assert rule_tier(@codex) == :privileged
    end
  end
end
