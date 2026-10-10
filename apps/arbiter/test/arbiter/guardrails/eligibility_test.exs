defmodule Arbiter.Guardrails.EligibilityTest do
  use ExUnit.Case, async: true

  alias Arbiter.Guardrails.Eligibility

  @rules [
    %{match: %{provider: "claude"}, tier: :privileged},
    %{match: %{provider: "antigravity", family: "anthropic"}, tier: :probation},
    %{
      match: %{provider: "antigravity", model: "gemini-*-flash-*"},
      tier: :quarantine,
      scope: %{"default" => ["arbiter"]}
    },
    %{match: %{provider: "antigravity"}, tier: :probation},
    %{match: %{provider: "codex"}, tier: :quarantine}
  ]

  @agreements %{"phi_data" => ["claude:default"]}

  defp ws(guardrails \\ nil) do
    config = if guardrails, do: %{"guardrails" => guardrails}, else: %{}
    %{id: "ws-1", name: "default", prefix: "bd", config: config}
  end

  defp attrs(provider, model, overrides) do
    Map.merge(
      %{
        provider: provider,
        model: model,
        account: %{provider: String.to_atom(provider), slug: "default"},
        role: :implementer,
        difficulty: 1,
        permissions: [],
        workspace: ws(),
        repo: nil
      },
      overrides
    )
  end

  defp evaluate(attrs, opts \\ []) do
    Eligibility.evaluate(attrs, Keyword.merge([rules: @rules, agreements: @agreements], opts))
  end

  describe "unguarded" do
    test "no subject rule configured is always eligible, with no profile" do
      assert {:ok, %{profile: nil, permission_fallback: []}} =
               evaluate(attrs("antigravity", "gemini-3.8-flash-low", %{difficulty: 5}),
                 rules: []
               )
    end
  end

  describe "suspension (G18)" do
    test "a suspended subject is ineligible for any role, whatever its tier allowed" do
      suspensions = %{
        {"claude", "claude-opus-4-6"} => %{"kind" => "public_upload_attempt", "run_id" => "r1"}
      }

      for role <- [:implementer, :reviewer] do
        assert {:error, detail} =
                 evaluate(attrs("claude", "claude-opus-4-6", %{role: role}),
                   suspensions: suspensions
                 )

        assert detail =~ "suspended"
        assert detail =~ "public_upload_attempt"
        assert detail =~ "arb trust"
      end

      assert {:ok, _} =
               evaluate(attrs("claude", "claude-sonnet-5-5", %{}), suspensions: suspensions)
    end
  end

  describe "difficulty" do
    test "an implementer above the tier's max_difficulty is ineligible" do
      assert {:error, detail} =
               evaluate(attrs("antigravity", "gemini-3.8-flash-low", %{difficulty: 2}))

      assert detail =~ "D2"
      assert detail =~ "quarantine"
    end

    test "a nil difficulty counts as D2" do
      assert {:error, _} =
               evaluate(attrs("antigravity", "gemini-3.8-flash-low", %{difficulty: nil}))

      assert {:ok, _} = evaluate(attrs("antigravity", "gemini-3.1-pro-high", %{difficulty: nil}))
    end

    test "a tier at its ceiling is eligible" do
      assert {:ok, %{profile: %{tier: :quarantine}}} =
               evaluate(attrs("antigravity", "gemini-3.8-flash-low", %{difficulty: 1}))
    end

    test "a subject that may not review is ineligible as a reviewer" do
      assert {:error, detail} =
               evaluate(
                 attrs("antigravity", "gemini-3.8-flash-low", %{role: :reviewer, difficulty: 1})
               )

      assert detail =~ "review"
    end

    test "a reviewer is bounded by max_review_difficulty, not max_difficulty" do
      assert {:ok, _} =
               evaluate(
                 attrs("antigravity", "gemini-3.1-pro-high", %{role: :reviewer, difficulty: 2})
               )

      assert {:error, _} =
               evaluate(
                 attrs("antigravity", "gemini-3.1-pro-high", %{role: :reviewer, difficulty: 3})
               )
    end
  end

  describe "scope" do
    test "a subject outside its rule's scope is ineligible" do
      scope_ws = %{ws() | name: "other", prefix: "ot", id: "ws-2"}

      assert {:error, detail} =
               evaluate(attrs("antigravity", "gemini-3.8-flash-low", %{workspace: scope_ws}))

      assert detail =~ "scope"
    end

    test "a repo outside the scope's repo list is ineligible" do
      assert {:error, _} =
               evaluate(attrs("antigravity", "gemini-3.8-flash-low", %{repo: "mesaana"}))

      assert {:ok, _} = evaluate(attrs("antigravity", "gemini-3.8-flash-low", %{repo: "arbiter"}))
    end
  end

  describe "action permissions (implementer)" do
    @binding %{"prod_read" => %{"enforced_read_only" => true, "env_from_secret" => %{"A" => "b"}}}

    test "a tier below the permission's min_tier is ineligible" do
      assert {:error, detail} =
               evaluate(
                 attrs("antigravity", "gemini-3.1-pro-high", %{
                   permissions: ["prod_read"],
                   workspace: ws(%{"bindings" => @binding})
                 })
               )

      assert detail =~ "prod_read"
    end

    test "a privileged tier with a binding is eligible" do
      assert {:ok, _} =
               evaluate(
                 attrs("claude", "claude-opus-4-6", %{
                   permissions: ["prod_read"],
                   difficulty: 3,
                   workspace: ws(%{"bindings" => @binding})
                 })
               )
    end

    test "a permission with no binding in the workspace is ineligible" do
      assert {:error, detail} =
               evaluate(
                 attrs("claude", "claude-opus-4-6", %{permissions: ["prod_read"], difficulty: 3})
               )

      assert detail =~ "binding"
    end

    test "an optional permission that is withheld does not make the subject ineligible" do
      assert {:ok,
              %{permission_fallback: [%{permission: "network?:status.example.com:443"} = fb]}} =
               evaluate(
                 attrs("antigravity", "gemini-3.8-flash-low", %{
                   permissions: ["network?:status.example.com:443"]
                 })
               )

      assert is_binary(fb.reason)
    end

    test "a required permission the same tier cannot hold is ineligible" do
      assert {:error, _} =
               evaluate(
                 attrs("antigravity", "gemini-3.8-flash-low", %{
                   permissions: ["network:api.example.com:443"]
                 })
               )
    end

    test "a reviewer is given no action permissions, so they never make it ineligible" do
      assert {:ok, _} =
               evaluate(
                 attrs("antigravity", "gemini-3.1-pro-high", %{
                   role: :reviewer,
                   difficulty: 2,
                   permissions: ["prod_ssh"]
                 })
               )
    end
  end

  describe "data classes (every role)" do
    test "phi_data needs a tier that may see it" do
      assert {:error, detail} =
               evaluate(attrs("antigravity", "gemini-3.1-pro-high", %{permissions: ["phi_data"]}))

      assert detail =~ "phi_data"
    end

    test "phi_data needs the account's agreement even at a trusted tier" do
      assert {:ok, _} =
               evaluate(attrs("claude", "claude-opus-4-6", %{permissions: ["phi_data"]}))

      assert {:error, detail} =
               evaluate(attrs("claude", "claude-opus-4-6", %{permissions: ["phi_data"]}),
                 agreements: %{}
               )

      assert detail =~ "agreement"
    end

    test "an account other than the agreed one is ineligible" do
      assert {:error, _} =
               evaluate(
                 attrs("claude", "claude-opus-4-6", %{
                   permissions: ["phi_data"],
                   account: %{provider: :claude, slug: "work"}
                 })
               )
    end

    test "no account to check is ineligible (fail closed)" do
      assert {:error, _} =
               evaluate(
                 attrs("claude", "claude-opus-4-6", %{permissions: ["phi_data"], account: nil})
               )
    end

    test "binds a reviewer too" do
      assert {:error, _} =
               evaluate(
                 attrs("claude", "claude-opus-4-6", %{role: :reviewer, permissions: ["phi_data"]}),
                 agreements: %{}
               )

      assert {:ok, _} =
               evaluate(
                 attrs("claude", "claude-opus-4-6", %{role: :reviewer, permissions: ["phi_data"]})
               )
    end
  end

  describe "agreements/0" do
    test "reads the installation's app env" do
      Application.put_env(:arbiter, :guardrail_data_agreements, %{"phi_data" => ["codex:main"]})
      on_exit(fn -> Application.delete_env(:arbiter, :guardrail_data_agreements) end)

      assert Eligibility.agreements() == %{"phi_data" => ["codex:main"]}
    end

    test "is empty by default" do
      assert Eligibility.agreements() == %{}
    end
  end
end
