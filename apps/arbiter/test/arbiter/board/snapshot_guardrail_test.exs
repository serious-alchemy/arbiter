defmodule Arbiter.Board.SnapshotGuardrailTest do
  @moduledoc """
  bd-atll60 (G13): a Ready ticket no model its guardrails allow can take — or
  one with a declared permission still awaiting a grant — is held on the board
  with `held — guardrail (<detail>)`, as its own block (it does not hold the
  queue behind it), so Autopilot plans past it
  (`docs/design/guardrail-profiles.md` §5.7).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.{Issue, Workspace}

  @rules [
    %{match: %{provider: "claude"}, tier: :privileged},
    %{match: %{provider: "codex"}, tier: :quarantine}
  ]

  setup do
    put_app_env(:arbiter, :guardrail_subject_rules, @rules)
    :ok
  end

  defp workspace!(types) do
    n = System.unique_integer([:positive])

    Ash.create!(Workspace, %{
      name: "sg-#{n}",
      prefix: "sg#{n}",
      config: %{"agent" => %{"type" => types}}
    })
  end

  defp issue(id, ws, extra) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        id: id,
        title: "Task #{id}",
        state: :queued,
        priority: 2,
        difficulty: 1,
        issue_type: :task,
        workspace_id: ws.id,
        description: nil,
        acceptance: nil,
        notes: nil,
        created_at: now,
        updated_at: now,
        closed_at: nil
      },
      extra
    )
  end

  defp load_ready(ws, issues) do
    board = Snapshot.load(workspace_id: ws.id, issues: issues, workers: [], slots_total: 3)
    Map.new(board.ready, &{&1.card.id, &1})
  end

  test "a ticket above every pool provider's ceiling is held, and the next one goes" do
    ws = workspace!(["codex"])
    stuck = issue("t-1", ws, %{difficulty: 3})
    fine = issue("t-2", ws, %{difficulty: 1})

    ready = load_ready(ws, [stuck, fine])

    assert %{state: :blocked, reason: reason, hold: {:guardrail, detail}} = ready["t-1"]
    assert reason =~ "held — guardrail (no eligible model"
    assert detail =~ "D3"
    assert %{state: :next} = ready["t-2"]
  end

  test "a pool with an eligible provider does not hold the card" do
    ws = workspace!(["codex", "claude"])
    assert %{"t-1" => %{state: :next}} = load_ready(ws, [issue("t-1", ws, %{difficulty: 3})])
  end

  test "unguarded, nothing is evaluated and the card is planned as before" do
    put_app_env(:arbiter, :guardrail_subject_rules, [])
    ws = workspace!(["codex"])
    assert %{"t-1" => %{state: :next}} = load_ready(ws, [issue("t-1", ws, %{difficulty: 3})])
  end

  test "a declared permission awaiting the operator's grant holds the card" do
    ws = workspace!(["claude"])

    real =
      Ash.create!(Issue, %{title: "needs prod", workspace_id: ws.id, permissions: ["prod_ssh"]},
        context: %{guardrail_authority: :coordinator, permission_actor: "coordinator:test"}
      )

    ready = load_ready(ws, [issue(real.id, ws, %{})])

    assert %{state: :blocked, reason: reason} = ready[real.id]
    assert reason == "held — guardrail (awaiting operator grant: prod_ssh)"
  end
end
