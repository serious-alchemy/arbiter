defmodule Arbiter.Guardrails.GateTest do
  @moduledoc """
  bd-atll60 (G13): the hard gate at every spawn site — the explicit and legacy
  dispatch paths that never see `ProviderRouting`'s candidates
  (`docs/design/guardrail-profiles.md` §9 G13).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Guardrails.Gate
  alias Arbiter.Tasks.{Issue, Workspace}

  @rules [
    %{match: %{provider: "claude"}, tier: :privileged},
    %{match: %{provider: "codex"}, tier: :quarantine}
  ]

  setup do
    on_exit(fn -> Application.delete_env(:arbiter, :guardrail_subject_rules) end)
    ws = Ash.create!(Workspace, %{name: "gate-#{System.unique_integer([:positive])}"})
    {:ok, ws: ws}
  end

  defp guard!, do: Application.put_env(:arbiter, :guardrail_subject_rules, @rules)

  defp task!(ws, attrs),
    do: Ash.create!(Issue, Map.merge(%{title: "gate me", workspace_id: ws.id}, attrs))

  test "unguarded, everything passes", %{ws: ws} do
    task = task!(ws, %{difficulty: 5})
    assert :ok = Gate.check(task, ws, :codex, "gpt-5")
  end

  test "a provider above its tier's difficulty ceiling is refused with the hold phrase", %{ws: ws} do
    guard!()
    task = task!(ws, %{difficulty: 3})

    assert {:error, {:guardrail_ineligible, :codex, phrase}} =
             Gate.check(task, ws, :codex, "gpt-5")

    assert phrase =~ "held — guardrail"
    assert phrase =~ "D3"
  end

  test "an eligible provider passes", %{ws: ws} do
    guard!()
    task = task!(ws, %{difficulty: 3})
    assert :ok = Gate.check(task, ws, :claude, "claude-opus-4-6")
  end

  test "a task id is loaded, and a ReviewGate synthetic id resolves to its base task", %{ws: ws} do
    guard!()
    task = task!(ws, %{difficulty: 3})

    assert {:error, {:guardrail_ineligible, :codex, _}} = Gate.check(task.id, ws, :codex, nil)
    synthetic = task.id <> "#review"
    assert {:error, {:guardrail_ineligible, :codex, _}} = Gate.check(synthetic, ws, :codex, nil)
  end

  test "guarded, a ticket that cannot be read fails closed", %{ws: ws} do
    guard!()

    assert {:error, {:guardrail_ineligible, :claude, phrase}} =
             Gate.check("bd-nope", ws, :claude, nil)

    assert phrase =~ "ticket"
  end

  test "a reviewer is judged by the review ceiling", %{ws: ws} do
    guard!()
    task = task!(ws, %{difficulty: 1})

    assert {:error, {:guardrail_ineligible, :codex, phrase}} =
             Gate.check(task, ws, :codex, nil, role: :reviewer)

    assert phrase =~ "review"
    assert :ok = Gate.check(task, ws, :claude, nil, role: :reviewer)
  end

  test "pick/5 keeps the eligible providers and explains the rest", %{ws: ws} do
    guard!()
    task = task!(ws, %{difficulty: 3})

    assert {[:claude], [{:codex, detail}]} =
             Gate.partition(task, ws, [:codex, :claude], fn _ -> nil end)

    assert detail =~ "D3"
  end
end
