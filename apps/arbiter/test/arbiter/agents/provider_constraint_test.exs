defmodule Arbiter.Agents.ProviderConstraintTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.ProviderConstraint
  alias Arbiter.Tasks.Issue

  describe "normalize/1" do
    test "nil, an empty map and blank lists clear the constraint" do
      assert {:ok, nil} = ProviderConstraint.normalize(nil)
      assert {:ok, nil} = ProviderConstraint.normalize(%{})
      assert {:ok, nil} = ProviderConstraint.normalize(%{"require" => [], "exclude" => nil})
    end

    test "accepts either key, atom or string, list or comma string" do
      assert {:ok, %{"require" => ["claude"]}} =
               ProviderConstraint.normalize(%{require: ["claude"]})

      assert {:ok, %{"exclude" => ["gemini", "codex"]}} =
               ProviderConstraint.normalize(%{"exclude" => "gemini, codex"})
    end

    test "agy and antigravity are the gemini adapter; entries are deduplicated" do
      assert {:ok, %{"exclude" => ["gemini"]}} =
               ProviderConstraint.normalize(%{"exclude" => ["agy", "Antigravity", "gemini"]})
    end

    test "require and exclude together are refused" do
      assert {:error, msg} =
               ProviderConstraint.normalize(%{"require" => ["claude"], "exclude" => ["codex"]})

      assert msg =~ "one of"
    end

    test "an unknown provider or key is refused" do
      assert {:error, msg} = ProviderConstraint.normalize(%{"require" => ["nope"]})
      assert msg =~ "nope"
      assert {:error, _} = ProviderConstraint.normalize(%{"prefer" => ["claude"]})
      assert {:error, _} = ProviderConstraint.normalize("claude")
    end
  end

  describe "allows?/2" do
    test "no constraint allows everything" do
      assert ProviderConstraint.allows?(nil, :gemini)
      assert ProviderConstraint.allows?(%Issue{provider_constraint: nil}, :gemini)
      assert ProviderConstraint.allows?(%Issue{provider_constraint: %{}}, :gemini)
    end

    test "exclude refuses only the listed providers" do
      c = %{"exclude" => ["gemini"]}
      refute ProviderConstraint.allows?(c, :gemini)
      refute ProviderConstraint.allows?(c, "gemini")
      refute ProviderConstraint.allows?(c, :antigravity)
      assert ProviderConstraint.allows?(c, :claude)
      assert ProviderConstraint.allows?(c, :codex)
    end

    test "require allows only the listed providers" do
      c = %{"require" => ["claude"]}
      assert ProviderConstraint.allows?(%Issue{provider_constraint: c}, :claude)
      refute ProviderConstraint.allows?(c, :gemini)
      refute ProviderConstraint.allows?(c, :codex)
    end
  end

  describe "describe/1 and refusal" do
    test "names the constraint" do
      assert ProviderConstraint.describe(%{"exclude" => ["gemini", "codex"]}) ==
               "exclude gemini, codex"

      assert ProviderConstraint.describe(%{"require" => ["claude"]}) == "require claude"
    end

    test "check/2 refuses with the held phrase" do
      task = %Issue{id: "bd-x", provider_constraint: %{"exclude" => ["gemini"]}}

      assert :ok = ProviderConstraint.check(task, :claude)

      assert {:error, {:provider_constraint, :gemini, phrase}} =
               ProviderConstraint.check(task, :gemini)

      assert phrase =~ "held — provider constraint (exclude gemini"
    end

    test "check/2 is :ok for an unconstrained task" do
      assert :ok = ProviderConstraint.check(%Issue{id: "bd-x"}, :gemini)
    end
  end

  describe "filter/2" do
    test "keeps the allowed providers in order" do
      task = %Issue{provider_constraint: %{"exclude" => ["gemini"]}}
      assert ProviderConstraint.filter(task, [:gemini, :claude, :codex]) == [:claude, :codex]
      assert ProviderConstraint.filter(%Issue{}, [:gemini, :claude]) == [:gemini, :claude]
    end
  end
end
