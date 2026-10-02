defmodule Arbiter.Agents.ReviewerRoutingTest do
  @moduledoc """
  bd-a1ke2c: the ReviewGate reviewer's model family must differ from the
  implementer's. `ReviewerRouting.select/3` is the one decision every review
  pass (rounds, re-reviews, print-timeout rotation) is routed through.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Agents
  alias Arbiter.Agents.{CredentialWatchdog, ModelFamily, ProviderPool, ReviewerRouting}
  alias Arbiter.Quota.{AnthropicQuota, CodexQuota, GoogleQuota}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workers.Run

  setup do
    on_exit(fn -> :ets.delete_all_objects(:arbiter_provider_circuit_breakers) end)
    :ok
  end

  # ---- fixtures -------------------------------------------------------------

  defp workspace!(types, extra \\ %{}) do
    review_agent =
      Map.merge(%{"type" => types, "cross_family" => true}, Map.get(extra, "review_agent", %{}))

    config = extra |> Map.delete("review_agent") |> Map.put("review_agent", review_agent)
    Ash.create!(Workspace, %{name: "rr-#{System.unique_integer([:positive])}", config: config})
  end

  defp account!(provider, slug, attrs \\ %{}) do
    Ash.create!(
      ProviderAccount,
      Map.merge(
        %{provider: provider, slug: "#{slug}-#{System.unique_integer([:positive])}"},
        attrs
      )
    )
  end

  defp allow_reviewer!(ws, account, position) do
    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: account.provider,
      provider_account_id: account.id,
      reviewer_position: position
    })
  end

  defp task!(ws, implementer_family) do
    task = Ash.create!(Issue, %{title: "review me", workspace_id: ws.id})

    if implementer_family do
      task
      |> Ash.Changeset.for_update(:pin_implementer, %{implementer_family: implementer_family})
      |> Ash.update!()
    else
      task
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp ahead(secs), do: DateTime.add(now(), secs, :second)

  defp claude_quota(u5) do
    %AnthropicQuota{
      provider: "claude",
      utilization_5h: u5,
      reset_5h_at: ahead(9_000),
      status_5h: "allowed",
      utilization_7d: 0.0,
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

  defp agy_quota(gemini_used, reset_in \\ 9_000) do
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
      reset_at: ahead(reset_in),
      snapshot: %{
        "models" => [
          bucket.("gemini_models", "5h", gemini_used, ahead(reset_in)),
          bucket.("gemini_models", "weekly", 0.0, ahead(302_400)),
          bucket.("claude_and_gpt_models", "5h", 0.0, ahead(9_000)),
          bucket.("claude_and_gpt_models", "weekly", 0.0, ahead(302_400))
        ]
      }
    }
  end

  defp quotas(pairs) do
    by_id = Map.new(pairs, fn {account, quota} -> {account.id, quota} end)
    fn account -> account && Map.get(by_id, account.id) end
  end

  defp opts(pairs \\ [], extra \\ []),
    do:
      Keyword.merge(
        [quota_fun: quotas(pairs), gemini_code: "antigravity", tier: "standard"],
        extra
      )

  defp expire!(adapter) do
    CredentialWatchdog.mark_expired(adapter, %Arbiter.Worker.StopReason{
      category: :auth_expired,
      summary: "credentials expired"
    })

    _ = :sys.get_state(CredentialWatchdog)

    on_exit(fn ->
      CredentialWatchdog.clear(adapter)
      _ = :sys.get_state(CredentialWatchdog)
    end)
  end

  # ---- opt-in ----------------------------------------------------------------

  describe "review_agent.cross_family" do
    test "is off by default, and select/3 then does nothing" do
      ws =
        Ash.create!(Workspace, %{
          name: "rr-off-#{System.unique_integer([:positive])}",
          config: %{"review_agent" => %{"type" => ["claude", "gemini"]}}
        })

      refute ReviewerRouting.enabled?(ws)
      assert ReviewerRouting.select(ws, task!(ws, "anthropic"), opts()) == :off
    end

    test "is on only for a literal true" do
      assert ReviewerRouting.enabled?(workspace!(["claude", "gemini"]))
      refute ReviewerRouting.enabled?(nil)
    end

    test "the workspace config validator accepts a boolean and rejects anything else" do
      assert {:ok, _} =
               Ash.create(Workspace, %{
                 name: "rr-ok-#{System.unique_integer([:positive])}",
                 config: %{"review_agent" => %{"cross_family" => false}}
               })

      assert {:error, error} =
               Ash.create(Workspace, %{
                 name: "rr-bad-#{System.unique_integer([:positive])}",
                 config: %{"review_agent" => %{"cross_family" => "yes"}}
               })

      assert Exception.message(error) =~ "review_agent.cross_family"
    end
  end

  # ---- AC1: a different family reviews -------------------------------------

  describe "the reviewer's family differs from the implementer's (AC1)" do
    test "Claude implements → the Google reviewer is chosen, even when Claude is listed first" do
      ws = workspace!(["claude", "gemini"])

      assert {:ok, sel} = ReviewerRouting.select(ws, task!(ws, "anthropic"), opts())
      assert sel.provider == :gemini
      assert sel.family == :google
      assert sel.implementer_family == :anthropic
      refute sel.same_family_fallback
      assert sel.fallback_reason == nil
    end

    test "Google implements → the Anthropic reviewer is chosen" do
      ws = workspace!(["gemini", "claude"])

      assert {:ok, sel} = ReviewerRouting.select(ws, task!(ws, "google"), opts())
      assert sel.provider == :claude
      assert sel.family == :anthropic
      assert sel.implementer_family == :google
      refute sel.same_family_fallback
    end

    test "the first pass pins the reviewer family on the task, and later passes keep it" do
      ws = workspace!(["gemini", "codex", "claude"])
      gemini = account!(:antigravity, "g")
      codex = account!(:codex, "c")
      allow_reviewer!(ws, gemini, 0)
      allow_reviewer!(ws, codex, 1)
      task = task!(ws, "anthropic")

      # Codex has the most headroom on the first pass, so openai is pinned.
      first = opts([{gemini, agy_quota(70.0)}, {codex, codex_quota(10.0)}])

      assert {:ok, %{family: :openai, outcome: "selected"}} =
               ReviewerRouting.select(ws, task, first)

      assert Ash.get!(Issue, task.id).reviewer_family == "openai"

      # Now Gemini has more room — but the task's reviewer family stays openai.
      later = opts([{gemini, agy_quota(0.0)}, {codex, codex_quota(60.0)}])

      assert {:ok, %{family: :openai, outcome: "pinned"}} =
               ReviewerRouting.select(ws, Ash.get!(Issue, task.id), later)
    end

    test "without a pin, the implementer family is read off the task's latest authoring run" do
      ws = workspace!(["claude", "gemini"])
      task = task!(ws, nil)

      Ash.create!(Run, %{
        task_id: task.id,
        base_task_id: task.id,
        repo: "trib/repo",
        kind: :implement,
        provider: "claude",
        started_at: DateTime.utc_now()
      })

      assert {:ok, sel} = ReviewerRouting.select(ws, task, opts())
      assert sel.implementer_family == :anthropic
      assert sel.family == :google
    end
  end

  describe "a provider switch mid-life (bd-avgph4)" do
    defp run!(task, provider, kind, started_at) do
      Ash.create!(Run, %{
        task_id: task.id,
        base_task_id: task.id,
        repo: "trib/repo",
        kind: kind,
        provider: provider,
        started_at: started_at
      })
    end

    test "the implementer family is the latest authoring run's, not the stale pin" do
      ws = workspace!(["claude", "gemini"])
      task = task!(ws, "google")
      run!(task, "antigravity", :implement, ahead(-600))
      run!(task, "claude", :fix_pass, ahead(-60))

      assert {:ok, sel} = ReviewerRouting.select(ws, Ash.get!(Issue, task.id), opts())
      assert sel.implementer_family == :anthropic
      assert sel.family == :google
      refute sel.same_family_fallback
    end

    test "a re-dispatch to another family re-resolves and re-pins the reviewer, recording why" do
      ws = workspace!(["claude", "gemini"])
      task = task!(ws, "google")
      run!(task, "antigravity", :implement, ahead(-600))

      assert {:ok, %{family: :anthropic, outcome: "selected"}} =
               ReviewerRouting.select(ws, Ash.get!(Issue, task.id), opts())

      assert Ash.get!(Issue, task.id).reviewer_family == "anthropic"

      run!(task, "claude", :implement, ahead(-60))

      assert {:ok, sel} = ReviewerRouting.select(ws, Ash.get!(Issue, task.id), opts())
      assert sel.implementer_family == :anthropic
      assert sel.family == :google
      assert sel.outcome == "repicked"
      assert sel.fallback_reason =~ "implementer family"
      assert sel.record["authoring_families"] == ["google", "anthropic"]
      assert Ash.get!(Issue, task.id).reviewer_family == "google"
    end

    test "switching to the only configured family records a same-family fallback" do
      ws = workspace!(["claude"])
      task = task!(ws, "google")
      run!(task, "claude", :implement, ahead(-60))

      assert {:ok, sel} = ReviewerRouting.select(ws, Ash.get!(Issue, task.id), opts())
      assert sel.implementer_family == :anthropic
      assert sel.same_family_fallback
    end
  end

  # ---- AC2: family comes from the model, not the CLI ------------------------

  describe "family is keyed on the model, not the CLI (AC2)" do
    test "an agy reviewer configured with a Claude model counts as Anthropic" do
      ws =
        workspace!(["gemini", "claude"], %{
          "review_agent" => %{
            "config" => %{"gemini" => %{"model" => "claude-opus-4-6-thinking"}}
          }
        })

      assert {:ok, sel} = ReviewerRouting.select(ws, task!(ws, "anthropic"), opts())

      # Both configured reviewers are Anthropic, so this can only be a recorded
      # same-family fallback — never a silent "cross-family" gemini review.
      assert sel.same_family_fallback
      assert sel.family == :anthropic
      assert sel.fallback_reason =~ "no other model family"
    end

    test "…and is ineligible whenever another family can review" do
      ws =
        workspace!(["gemini", "codex"], %{
          "review_agent" => %{
            "config" => %{"gemini" => %{"model" => "claude-opus-4-6-thinking"}}
          }
        })

      assert {:ok, sel} = ReviewerRouting.select(ws, task!(ws, "anthropic"), opts())
      assert sel.provider == :codex
      assert sel.family == :openai
      refute sel.same_family_fallback
    end
  end

  # ---- AC3: most quota left, the family's reviewer tier ----------------------

  describe "paused providers (bd-5ef587)" do
    test "a paused account is dropped with reason paused, and the pass re-routes" do
      ws = workspace!(["gemini", "codex"])
      gemini = account!(:antigravity, "g")
      codex = account!(:codex, "c")
      allow_reviewer!(ws, gemini, 0)
      allow_reviewer!(ws, codex, 1)
      {:ok, _} = Arbiter.Providers.Pause.pause(gemini.id, reason: "jail escape", by: "test")

      assert {:ok, sel} =
               ReviewerRouting.select(
                 ws,
                 task!(ws, "anthropic"),
                 opts([{gemini, agy_quota(0.0)}, {codex, codex_quota(50.0)}])
               )

      assert sel.provider == :codex
      refute sel.same_family_fallback
      assert Enum.any?(sel.record["dropped"], &(&1["reason"] == "paused"))
    end

    test "paused counts like quota_held: the only other family paused → recorded same-family fallback" do
      ws = workspace!(["claude", "codex"])
      claude = account!(:claude, "a")
      codex = account!(:codex, "c")
      allow_reviewer!(ws, claude, 0)
      allow_reviewer!(ws, codex, 1)
      {:ok, _} = Arbiter.Providers.Pause.pause("codex", reason: "x", by: "test")

      assert {:ok, sel} =
               ReviewerRouting.select(
                 ws,
                 task!(ws, "anthropic"),
                 opts([{claude, claude_quota(0.0)}, {codex, codex_quota(0.0)}])
               )

      assert sel.same_family_fallback
      assert sel.fallback_reason =~ "paused"
    end
  end

  describe "among eligible families, the most quota left wins (AC3)" do
    setup do
      ws = workspace!(["gemini", "codex", "claude"])
      gemini = account!(:antigravity, "g")
      codex = account!(:codex, "c")
      claude = account!(:claude, "a")
      allow_reviewer!(ws, gemini, 0)
      allow_reviewer!(ws, codex, 1)
      allow_reviewer!(ws, claude, 2)
      %{ws: ws, gemini: gemini, codex: codex, claude: claude}
    end

    test "codex has more headroom than gemini → openai reviews", c do
      pairs = [
        {c.gemini, agy_quota(60.0)},
        {c.codex, codex_quota(5.0)},
        {c.claude, claude_quota(0.0)}
      ]

      assert {:ok, sel} = ReviewerRouting.select(c.ws, task!(c.ws, "anthropic"), opts(pairs))
      assert sel.family == :openai
      assert sel.account_id == c.codex.id
    end

    test "gemini has more headroom than codex → google reviews", c do
      pairs = [
        {c.gemini, agy_quota(5.0)},
        {c.codex, codex_quota(60.0)},
        {c.claude, claude_quota(0.0)}
      ]

      assert {:ok, sel} = ReviewerRouting.select(c.ws, task!(c.ws, "anthropic"), opts(pairs))
      assert sel.family == :google
      assert sel.account_id == c.gemini.id
    end

    test "the implementer's own family never wins on headroom", c do
      pairs = [
        {c.gemini, agy_quota(50.0)},
        {c.codex, codex_quota(50.0)},
        {c.claude, claude_quota(0.0)}
      ]

      assert {:ok, sel} = ReviewerRouting.select(c.ws, task!(c.ws, "anthropic"), opts(pairs))
      refute sel.family == :anthropic
    end
  end

  describe "the reviewer tier (AC3)" do
    test "a Google reviewer runs Gemini's top model at high effort, never a flash tier" do
      ws = workspace!(["gemini"])

      for tier <- ["economy", "standard", "premium"] do
        assert {:ok, sel} =
                 ReviewerRouting.select(ws, task!(ws, "anthropic"), opts([], tier: tier))

        assert sel.family == :google
        assert sel.tier == "premium"
        assert sel.model == "gemini-3.1-pro-high"
        assert sel.thinking == "high"
      end
    end

    test "an Anthropic reviewer keeps the task's reviewer tier" do
      ws = workspace!(["claude"])

      assert {:ok, sel} =
               ReviewerRouting.select(ws, task!(ws, "google"), opts([], tier: "standard"))

      assert sel.tier == "standard"
      assert sel.model == ModelFamily.model_for_tier(:claude, "standard", %{})
    end

    test "ModelFamily names the reviewer tier floor per family" do
      assert ModelFamily.reviewer_tier(:google, "economy") == "premium"
      assert ModelFamily.reviewer_tier(:anthropic, "economy") == "economy"
      assert ModelFamily.reviewer_thinking(:google, nil) == "high"
      assert ModelFamily.reviewer_thinking(:anthropic, nil) == nil
    end
  end

  # ---- AC4: same-family fallback, only on the listed triggers ------------------

  describe "same-family fallback (AC4)" do
    test "unconfigured: no other family in review_agent.type" do
      ws = workspace!(["claude"])

      assert {:ok, sel} = ReviewerRouting.select(ws, task!(ws, "anthropic"), opts())
      assert sel.same_family_fallback
      assert sel.provider == :claude
      assert sel.fallback_reason =~ "no other model family configured"
    end

    test "quota-held (paced included): the other family's account is held" do
      ws = workspace!(["gemini", "claude"])

      held =
        account!(:antigravity, "held", %{
          quota_config: %{"threshold_mode" => "paced", "paced_floor" => 0.35}
        })

      allow_reviewer!(ws, held, 0)
      allow_reviewer!(ws, account!(:claude, "a"), 1)

      # 5h window reset 4.9h out: the paced line is the 0.35 floor, so 40%
      # used is held though far under the flat default ceiling.
      quota = agy_quota(40.0, 17_640)

      assert {:ok, sel} =
               ReviewerRouting.select(ws, task!(ws, "anthropic"), opts([{held, quota}]))

      assert sel.same_family_fallback
      assert sel.family == :anthropic
      assert sel.fallback_reason =~ "google"
      assert sel.fallback_reason =~ "quota_held"
    end

    test "auth-expired: the other family's adapter credential is expired" do
      ws = workspace!(["gemini", "claude"])
      expire!(Agents.Gemini)

      assert {:ok, sel} = ReviewerRouting.select(ws, task!(ws, "anthropic"), opts())
      assert sel.same_family_fallback
      assert sel.fallback_reason =~ "auth_expired"
    end

    test "circuit-broken: the other family's adapter is in cooldown" do
      ws = workspace!(["gemini", "claude"])
      ProviderPool.mark_exhausted(:gemini)

      assert {:ok, sel} = ReviewerRouting.select(ws, task!(ws, "anthropic"), opts())
      assert sel.same_family_fallback
      assert sel.provider == :claude
      assert sel.fallback_reason =~ "circuit_broken"
    end

    test "a fallback does not move the task's reviewer-family pin" do
      ws = workspace!(["gemini", "claude"])
      task = task!(ws, "anthropic")

      assert {:ok, %{family: :google}} = ReviewerRouting.select(ws, task, opts())
      ProviderPool.mark_exhausted(:gemini)

      assert {:ok, %{same_family_fallback: true}} =
               ReviewerRouting.select(ws, Ash.get!(Issue, task.id), opts())

      assert Ash.get!(Issue, task.id).reviewer_family == "google"
    end

    test "a pinned family that becomes unavailable is re-picked among the other eligible families first" do
      ws = workspace!(["gemini", "codex", "claude"])
      task = task!(ws, "anthropic")

      assert {:ok, %{family: :google}} = ReviewerRouting.select(ws, task, opts())

      ProviderPool.mark_exhausted(:gemini)

      assert {:ok, sel} = ReviewerRouting.select(ws, Ash.get!(Issue, task.id), opts())
      assert sel.family == :openai
      assert sel.outcome == "repicked"
      refute sel.same_family_fallback
      assert Ash.get!(Issue, task.id).reviewer_family == "openai"

      # Only once every other family is gone does it fall back.
      ProviderPool.mark_exhausted(:codex)

      assert {:ok, sel} = ReviewerRouting.select(ws, Ash.get!(Issue, task.id), opts())
      assert sel.same_family_fallback
      assert sel.family == :anthropic
    end

    test "a provider excluded by the print-timeout rotation is not a fallback trigger" do
      ws = workspace!(["gemini", "claude"])

      assert {:none, record} =
               ReviewerRouting.select(ws, task!(ws, "anthropic"), opts([], exclude: [:gemini]))

      assert record["reason"] =~ "timed_out"
    end

    test "with no reviewer available at all the pass still runs at once, on the legacy reviewer, recorded" do
      ws = workspace!(["claude", "gemini"])
      ProviderPool.mark_exhausted(:gemini)
      ProviderPool.mark_exhausted(:claude)

      assert {:ok, sel} = ReviewerRouting.select(ws, task!(ws, "anthropic"), opts())
      assert sel.outcome == "no_candidate"
      assert sel.provider in [:claude, :gemini]
      assert sel.fallback_reason =~ "no reviewer available"
    end
  end

  # ---- bd-13pqcp: the implementer's provider constraint is not the reviewer's --

  describe "a per-ticket provider constraint does not constrain the reviewer (bd-13pqcp)" do
    test "require claude (the implementer's) still gets a Google reviewer — the cross-family rule decides" do
      ws = workspace!(["claude", "gemini"])

      task =
        ws
        |> task!("anthropic")
        |> Ash.update!(%{provider_constraint: %{"require" => ["claude"]}})

      assert task.provider_constraint == %{"require" => ["claude"]}

      assert {:ok, sel} = ReviewerRouting.select(ws, task, opts())
      assert sel.agent_type == "gemini"
      assert sel.implementer_family == :anthropic
      refute sel.same_family_fallback
    end

    test "exclude gemini (the implementer's) still lets gemini review" do
      ws = workspace!(["claude", "gemini"])

      task =
        ws
        |> task!("anthropic")
        |> Ash.update!(%{provider_constraint: %{"exclude" => ["gemini"]}})

      assert {:ok, sel} = ReviewerRouting.select(ws, task, opts())
      assert sel.agent_type == "gemini"
    end
  end
end
