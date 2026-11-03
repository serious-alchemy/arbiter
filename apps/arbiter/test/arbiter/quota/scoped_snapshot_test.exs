defmodule Arbiter.Quota.ScopedSnapshotTest do
  @moduledoc """
  bd-e0b7so (5H C6) AC1, AC2, AC5, AC6: per-model `weekly_scoped` limits as
  nested windows of the `claude` pool — parsed from `limits[]`, carried on
  `Gate.Snapshot.scoped`, and projected per model by `Snapshot.normalize/2`.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.OAuthUsage
  alias Arbiter.Quota.OAuthUsageFixtures

  @reset ~U[2026-11-02 15:59:59Z]

  defp scoped(scope, util, opts \\ []) do
    %{
      "scope" => scope,
      "utilization" => util,
      "status" => Keyword.get(opts, :status, "allowed"),
      "reset_at" => DateTime.to_iso8601(Keyword.get(opts, :reset_at, @reset)),
      "is_active" => Keyword.get(opts, :active, false)
    }
  end

  defp row(scoped_limits) do
    %AnthropicQuota{
      provider: "claude",
      utilization_7d: 0.61,
      status_7d: "allowed",
      reset_7d_at: @reset,
      captured_at: ~U[2026-11-02 12:00:00Z],
      capture_source: "oauth_poll",
      scoped_limits: scoped_limits
    }
  end

  describe "ModelFamily.scope_matches?/2 (AC5)" do
    test "a display name matches the model ids and aliases that carry its tokens" do
      assert ModelFamily.scope_matches?("Fable", "claude-fable-5-1")
      assert ModelFamily.scope_matches?("Fable", "fable")
      assert ModelFamily.scope_matches?("Fable", "Claude-Fable-5-1")
      assert ModelFamily.scope_matches?("Sonnet", "claude-sonnet-5-5")
      assert ModelFamily.scope_matches?("Opus", "opus")
    end

    test "it does not match another model, nil, or a substring of a longer word" do
      refute ModelFamily.scope_matches?("Fable", "claude-opus-5-5")
      refute ModelFamily.scope_matches?("Fable", nil)
      refute ModelFamily.scope_matches?("Opus", "claude-sonnet-5-5")
      refute ModelFamily.scope_matches?("Fab", "claude-fable-5-1")
    end

    test "known_scope?/1 names the Claude model families we route to" do
      for name <- ~w(Fable Opus Sonnet Haiku), do: assert(ModelFamily.known_scope?(name))
      refute ModelFamily.known_scope?("Mythos")
      refute ModelFamily.known_scope?(nil)
    end
  end

  describe "OAuthUsage.parse_usage/1 (AC1)" do
    test "the recorded live shape yields a scoped window per weekly_scoped limit" do
      usage = OAuthUsage.parse_usage(OAuthUsageFixtures.five_hour_null())

      assert [%{"scope" => "Fable", "utilization" => +0.0, "status" => "allowed"} = w] =
               usage.scoped

      assert w["reset_at"] =~ "2026-11-02T15:59:59"
      assert w["is_active"] == false
    end

    test "the legacy shape has no scoped window" do
      assert OAuthUsage.parse_usage(OAuthUsageFixtures.legacy()).scoped == []
    end

    test "a rejected, active scoped limit carries its status and activity" do
      usage = OAuthUsage.parse_usage(OAuthUsageFixtures.scoped_exhausted())

      assert [%{"scope" => "Fable", "utilization" => 1.0, "status" => "rejected"} = w] =
               usage.scoped

      assert w["is_active"] == true
    end

    test "a scoped limit without a display name or percent is not reported" do
      body =
        Map.put(OAuthUsageFixtures.five_hour_null(), "limits", [
          %{"kind" => "weekly_scoped", "percent" => 50, "scope" => %{"model" => %{}}},
          %{
            "kind" => "weekly_scoped",
            "scope" => %{"model" => %{"display_name" => "Fable"}}
          }
        ])

      assert OAuthUsage.parse_usage(body).scoped == []
    end
  end

  describe "Snapshot.normalize/2 (AC1, AC2)" do
    defp fable, do: scoped("Fable", 0.7)
    defp sonnet, do: scoped("Sonnet", 0.2)

    test "without a :model option the row projects no scoped windows" do
      assert %Snapshot{scoped: []} = Snapshot.normalize(row([fable()]))
    end

    test "a matching model gets exactly its scoped window, shaped for the gate" do
      assert %Snapshot{scoped: [w]} =
               Snapshot.normalize(row([fable(), sonnet()]), model: "claude-fable-5-1")

      assert %{scope: "Fable", label: "7d (Fable)", utilization: 0.7, status: "allowed"} = w
      assert w.reset_at == @reset
    end

    test "the base 7d window stays on the secondary fields" do
      s = Snapshot.normalize(row([fable()]), model: "claude-fable-5-1")
      assert s.secondary_window_label == "7d"
      assert s.secondary_utilization == 0.61
    end

    test "another model gets no scoped window" do
      assert %Snapshot{scoped: []} =
               Snapshot.normalize(row([fable()]), model: "claude-opus-5-5")
    end

    test "a nil model gets every matched scoped window: the worst of all" do
      assert %Snapshot{scoped: windows} =
               Snapshot.normalize(row([fable(), sonnet()]), model: nil)

      assert Enum.map(windows, & &1.scope) |> Enum.sort() == ["Fable", "Sonnet"]
    end

    test ":unscoped is a card on a model no scoped limit covers" do
      assert %Snapshot{scoped: []} = Snapshot.normalize(row([fable()]), model: :unscoped)
    end

    test "a row without scoped limits is unchanged (AC6)" do
      for model <- [nil, "claude-fable-5-1", :unscoped] do
        assert %Snapshot{scoped: []} = Snapshot.normalize(row([]), model: model)
      end

      assert %Snapshot{scoped: []} = Snapshot.normalize(row(nil), model: nil)
    end

    test "an unmatched scope is not gated unless it is active (AC5)" do
      idle = scoped("Mythos", 0.99)
      active = scoped("Mythos", 0.99, active: true)

      for model <- [nil, "claude-opus-5-5", :unscoped] do
        assert %Snapshot{scoped: []} = Snapshot.normalize(row([idle]), model: model)

        assert %Snapshot{scoped: [%{scope: "Mythos"}]} =
                 Snapshot.normalize(row([active]), model: model)
      end
    end

    test "a pre-built snapshot is filtered by the model it is asked for" do
      built = Snapshot.normalize(row([fable(), sonnet()]), model: nil)
      assert %Snapshot{scoped: [%{scope: "Sonnet"}]} = Snapshot.normalize(built, model: "sonnet")
      assert ^built = Snapshot.normalize(built)
    end

    test "a malformed stored window is skipped, never raised on" do
      bad = [%{"scope" => "Fable"}, %{"utilization" => 0.5}, "junk", scoped("Fable", 0.3)]

      assert %Snapshot{scoped: [%{utilization: 0.3}]} =
               Snapshot.normalize(row(bad), model: "fable")
    end
  end
end
