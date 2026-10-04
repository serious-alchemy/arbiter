defmodule Arbiter.Guardrails.SubjectsTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Guardrails
  alias Arbiter.Guardrails.Rules
  alias Arbiter.Guardrails.Subjects

  defp put(attrs, authority), do: Subjects.put(attrs, authority)

  test "no rows is no rules, and guardrails stay off" do
    assert Subjects.rules() == []
    assert Guardrails.effective(Guardrails.subject("claude", "m"), nil, nil) == nil
  end

  test "the operator creates a rule; effective/4 reads it from the table" do
    assert {:ok, _} = put(%{provider: "claude", tier: :privileged}, :operator)
    assert {:ok, _} = put(%{provider: "antigravity", model: "gemini-*-flash-*", tier: :quarantine, scope: %{"default" => ["arbiter"]}}, :operator)

    assert [%{tier: :privileged}, %{tier: :quarantine, scope: %{"default" => ["arbiter"]}}] =
             Subjects.rules()

    assert %{tier: :quarantine} = Guardrails.effective(Guardrails.subject("antigravity", "gemini-3.8-flash-low"), nil, nil)
    assert %{tier: :quarantine} = Guardrails.effective(Guardrails.subject("grok", "x"), nil, nil)
    assert %{tier: :privileged} = Guardrails.effective(Guardrails.subject("claude", "x"), nil, nil)
  end

  test "string keys are accepted and unknown keys ignored" do
    assert {:ok, row} = put(%{"provider" => "codex", "tier" => "quarantine", "bogus" => 1}, :operator)
    assert row.tier == :quarantine
  end

  test "a rule needs at least one match key" do
    assert {:error, _} = put(%{tier: :quarantine}, :operator)
  end

  test "a coordinator can create only a quarantine rule, and demote" do
    assert {:error, {:operator_only, msg}} = put(%{provider: "claude", tier: :trusted}, :coordinator)
    assert msg =~ "operator-only"
    assert Subjects.list() == []

    assert {:ok, _} = put(%{provider: "claude", tier: :quarantine}, :coordinator)

    assert {:ok, _} = put(%{provider: "codex", tier: :trusted}, :operator)
    assert {:ok, demoted} = put(%{provider: "codex", tier: :probation}, :coordinator)
    assert demoted.tier == :probation
  end

  test "a coordinator can neither promote nor widen a scope nor unpin" do
    {:ok, _} = put(%{provider: "codex", tier: :probation, scope: %{"default" => ["arbiter"]}, pinned: true}, :operator)

    assert {:error, {:operator_only, _}} = put(%{provider: "codex", tier: :trusted}, :coordinator)
    assert {:error, {:operator_only, _}} = put(%{provider: "codex", scope: nil}, :coordinator)
    assert {:error, {:operator_only, _}} = put(%{provider: "codex", scope: %{"default" => ["arbiter", "x"]}}, :coordinator)
    assert {:error, {:operator_only, _}} = put(%{provider: "codex", pinned: false}, :coordinator)

    assert [%{tier: :probation, pinned: true}] = Subjects.rules()
  end

  test "restricted authority can do nothing that loosens" do
    assert {:error, {:operator_only, _}} = put(%{provider: "claude", tier: :privileged}, :restricted)
  end

  test "delete: operator-only unless the rule was quarantine" do
    {:ok, _} = put(%{provider: "codex", tier: :probation}, :operator)
    {:ok, _} = put(%{provider: "grok", tier: :quarantine}, :operator)

    assert {:error, {:operator_only, _}} = Subjects.delete(%{provider: "codex"}, :coordinator)
    assert :ok = Subjects.delete(%{provider: "grok"}, :coordinator)
    assert :ok = Subjects.delete(%{provider: "codex"}, :operator)
    assert Subjects.rules() == []
  end

  test "app-env rules follow the DB's" do
    Application.put_env(:arbiter, :guardrail_subject_rules, [%{match: %{provider: "codex"}, tier: :quarantine}, %{"match" => %{"provider" => "bad"}, "tier" => "nope"}])
    on_exit(fn -> Application.delete_env(:arbiter, :guardrail_subject_rules) end)

    {:ok, _} = put(%{provider: "claude", tier: :privileged}, :operator)
    assert [%{source: :db}, %{source: :env, tier: :quarantine}] = Rules.all()
  end
end
