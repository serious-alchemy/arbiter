defmodule Arbiter.Agents.ReviewerRoutingGuardrailsTest do
  @moduledoc """
  bd-atll60 (G13): guardrail eligibility in `ReviewerRouting`
  (`docs/design/guardrail-profiles.md` §3.3, §5.4, §5.7, §8) — data-class and
  review-ceiling eligibility for reviewers, `guardrail_ineligible` as a
  same-family-fallback trigger, and the profile's `review` knobs.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.ReviewerRouting
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workers.Run

  # Claude implements (privileged); agy reviews at probation (D2 at most).
  @rules [
    %{match: %{provider: "claude"}, tier: :privileged},
    %{match: %{provider: "antigravity"}, tier: :probation}
  ]

  setup do
    on_exit(fn ->
      Application.delete_env(:arbiter, :guardrail_subject_rules)
      Application.delete_env(:arbiter, :guardrail_data_agreements)
      :ets.delete_all_objects(:arbiter_provider_circuit_breakers)
    end)

    :ok
  end

  defp guard!(rules \\ @rules),
    do: Application.put_env(:arbiter, :guardrail_subject_rules, rules)

  defp workspace!(cross_family \\ true, types \\ ["claude", "gemini"]) do
    review_agent = %{"type" => types, "cross_family" => cross_family}

    Ash.create!(Workspace, %{
      name: "rrg-#{System.unique_integer([:positive])}",
      config: %{"review_agent" => review_agent}
    })
  end

  defp task!(ws, attrs, context \\ %{}) do
    task =
      Ash.create!(Issue, Map.merge(%{title: "review me", workspace_id: ws.id}, attrs),
        context: context
      )

    Ash.create!(Run, %{
      task_id: task.id,
      base_task_id: task.id,
      repo: "trib/repo",
      kind: :implement,
      provider: "claude",
      started_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })

    task
  end

  defp opts(extra \\ []),
    do:
      Keyword.merge(
        [
          quota_fun: fn _ -> nil end,
          gemini_code: "antigravity",
          tier: "standard",
          write_confinement: fn _adapter, _policy -> :os_jail end,
          egress_confinement: fn _adapter, _policy -> :os_jail end
        ],
        extra
      )

  defp dropped_reasons(record), do: Map.new(record["dropped"], &{&1["provider"], &1["reason"]})

  test "unguarded, the reviewer pick is untouched" do
    ws = workspace!()

    assert {:ok, %{provider: :gemini, same_family_fallback: false}} =
             ReviewerRouting.select(ws, task!(ws, %{difficulty: 3}), opts())
  end

  test "a reviewer above its review ceiling is dropped, and the pass falls back to the implementer's family" do
    guard!()
    ws = workspace!()

    # D3 is above the probation review ceiling (D2): agy may not review it.
    assert {:ok, sel} = ReviewerRouting.select(ws, task!(ws, %{difficulty: 3}), opts())

    assert sel.provider == :claude
    assert sel.same_family_fallback
    assert sel.fallback_reason =~ "guardrail_ineligible"
    assert dropped_reasons(sel.record)["gemini"] == "guardrail_ineligible"
  end

  test "within the ceiling the cross-family reviewer is chosen as before" do
    guard!()
    ws = workspace!()

    assert {:ok, %{provider: :gemini, same_family_fallback: false}} =
             ReviewerRouting.select(ws, task!(ws, %{difficulty: 2}), opts())
  end

  test "same_family_fallback: hold means the review waits instead of reviewing itself" do
    guard!([
      %{
        match: %{provider: "claude"},
        tier: :privileged,
        overrides: %{review: %{same_family_fallback: :hold}}
      }
      | tl(@rules)
    ])

    ws = workspace!()

    assert {:none, record} = ReviewerRouting.select(ws, task!(ws, %{difficulty: 3}), opts())
    assert record["guardrail_hold"] =~ "same-family"
  end

  test "a data class that no reviewer family may see holds the review" do
    guard!()
    Application.put_env(:arbiter, :guardrail_data_agreements, %{"phi_data" => []})
    ws = workspace!()

    task =
      task!(ws, %{difficulty: 1, permissions: ["phi_data"]}, %{
        guardrail_authority: :coordinator,
        permission_actor: "t"
      })

    assert {:none, record} = ReviewerRouting.select(ws, task, opts())
    assert record["guardrail_hold"] =~ "phi_data"
  end

  describe "the profile's review knobs" do
    @quarantined_claude [
      %{match: %{provider: "claude"}, tier: :quarantine},
      %{match: %{provider: "antigravity"}, tier: :privileged}
    ]

    test "cross_family: required forces cross-family review although the workspace has it off" do
      guard!(@quarantined_claude)
      ws = workspace!(false)
      task = task!(ws, %{difficulty: 1})

      refute ReviewerRouting.enabled?(ws)
      assert ReviewerRouting.applies?(ws, task)

      assert {:ok, %{provider: :gemini, same_family_fallback: false}} =
               ReviewerRouting.select(ws, task, opts())
    end

    test "with the workspace off and no guardrail requirement, select/3 is still :off" do
      guard!()
      ws = workspace!(false)
      task = task!(ws, %{difficulty: 1})

      refute ReviewerRouting.applies?(ws, task)
      assert ReviewerRouting.select(ws, task, opts()) == :off
    end

    test "min_reviewer_tier raises the reviewer's tier" do
      guard!([
        %{match: %{provider: "claude"}, tier: :quarantine},
        %{match: %{provider: "codex"}, tier: :privileged}
      ])

      ws = workspace!(true, ["codex"])
      assert {:ok, sel} = ReviewerRouting.select(ws, task!(ws, %{difficulty: 1}), opts())
      assert sel.provider == :codex
      assert sel.tier == "premium"

      guard!([
        %{match: %{provider: "claude"}, tier: :privileged},
        %{match: %{provider: "codex"}, tier: :privileged}
      ])

      assert {:ok, %{tier: "standard"}} =
               ReviewerRouting.select(ws, task!(ws, %{difficulty: 1}), opts())
    end
  end
end
