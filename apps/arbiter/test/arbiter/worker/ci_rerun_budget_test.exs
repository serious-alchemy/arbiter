defmodule Arbiter.Worker.CiRerunBudgetTest do
  @moduledoc """
  GitHub #1284 — one per-SHA tally of automatic CI re-runs, shared by every
  site that re-runs CI (Watchdog flake / triage / cancelled / hold re-runs, the
  ReviewGate's CI wait), capped by `merge.ci.max_reruns_per_sha`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.CiRerunBudget

  @sha "aaaaaaa1111111111111111111111111111111aa"
  @other "bbbbbbb2222222222222222222222222222222bb"

  defp workspace(ci \\ %{}) do
    config = if ci == %{}, do: %{}, else: %{"merge" => %{"ci" => ci}}

    Ash.create!(Workspace, %{
      name: "ws-#{System.unique_integer([:positive])}",
      prefix: "rb#{System.unique_integer([:positive])}",
      config: config
    })
  end

  defp task(ws),
    do: Ash.create!(Issue, %{title: "rerun budget", description: "body", workspace_id: ws.id})

  describe "limit/2" do
    test "defaults to #{CiRerunBudget.default_limit()}" do
      assert CiRerunBudget.limit(workspace(), nil) == CiRerunBudget.default_limit()
    end

    test "is configurable through merge.ci.max_reruns_per_sha, 0 allowed" do
      assert CiRerunBudget.limit(workspace(%{"max_reruns_per_sha" => 5}), nil) == 5
      assert CiRerunBudget.limit(workspace(%{"max_reruns_per_sha" => 0}), nil) == 0
    end

    test "a junk value falls back to the default" do
      ws = workspace(%{"max_reruns_per_sha" => -1})
      assert CiRerunBudget.limit(ws, nil) == CiRerunBudget.default_limit()
      ws = workspace(%{"max_reruns_per_sha" => "lots"})
      assert CiRerunBudget.limit(ws, nil) == CiRerunBudget.default_limit()
    end
  end

  describe "check/3 and record/3" do
    test "allows re-runs up to the limit, then refuses with the tally" do
      t = task(workspace())

      assert :ok = CiRerunBudget.check(t.id, @sha, 2)
      assert {:ok, 1} = CiRerunBudget.record(t.id, @sha, :flake)
      assert :ok = CiRerunBudget.check(t.id, @sha, 2)
      assert {:ok, 2} = CiRerunBudget.record(t.id, @sha, :triage)

      assert {:capped, %{count: 2, limit: 2, sources: sources}} =
               CiRerunBudget.check(t.id, @sha, 2)

      assert sources == %{"flake" => 1, "triage" => 1}
    end

    test "a first failure followed by one re-run is allowed (default limit)" do
      t = task(workspace())
      assert :ok = CiRerunBudget.check(t.id, @sha, CiRerunBudget.default_limit())
    end

    test "a different SHA starts from zero: a push resets the count" do
      t = task(workspace())
      {:ok, 1} = CiRerunBudget.record(t.id, @sha, :flake)
      assert {:capped, _} = CiRerunBudget.check(t.id, @sha, 1)

      assert :ok = CiRerunBudget.check(t.id, @other, 1)
      assert {:ok, 1} = CiRerunBudget.record(t.id, @other, :flake)
      assert CiRerunBudget.count(t.id, @sha) == 0
    end

    test "limit 0 refuses every automatic re-run" do
      t = task(workspace())
      assert {:capped, %{count: 0, limit: 0}} = CiRerunBudget.check(t.id, @sha, 0)
    end

    test "an unknown head cannot be tallied and fails open" do
      t = task(workspace())
      assert :ok = CiRerunBudget.check(t.id, nil, 0)
      assert {:ok, 0} = CiRerunBudget.record(t.id, nil, :flake)
    end

    test "a short sha prefix is the same head" do
      t = task(workspace())
      {:ok, 1} = CiRerunBudget.record(t.id, @sha, :flake)
      assert {:capped, _} = CiRerunBudget.check(t.id, String.slice(@sha, 0, 8), 1)
    end
  end

  describe "note_capped/4" do
    test "writes one ticket note naming the failing jobs, once per sha" do
      t = task(workspace())
      {:ok, 1} = CiRerunBudget.record(t.id, @sha, :flake)
      info = %{count: 1, limit: 1, sources: %{"flake" => 1}}

      assert :noted = CiRerunBudget.note_capped(t.id, @sha, info, ["mix test", "credo"])
      assert :already_noted = CiRerunBudget.note_capped(t.id, @sha, info, ["mix test"])

      notes = Ash.get!(Issue, t.id).notes
      assert notes =~ "mix test, credo"
      assert notes =~ @sha
      assert notes =~ "merge.ci.max_reruns_per_sha"
      assert length(String.split(notes, "## CI re-run cap reached")) == 2
    end
  end
end
