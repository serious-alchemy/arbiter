defmodule Arbiter.Worker.DepsSeedWatchTest do
  @moduledoc """
  bd-175f0r: a deps seed that keeps failing for a repo/image must surface as a
  system alert naming the repo, digest and first error line, and the per-spawn
  warning is logged once per digest+error.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Alerts
  alias Arbiter.Worker.DepsSeedWatch

  @image "localhost/arbiter-dev/beam-1.19:abc123def456"
  @reason {:seed_failed, 1, "** (RuntimeError) DATABASE_URL is not set\n  stacktrace line"}

  setup do
    DepsSeedWatch.reset()
    on_exit(&DepsSeedWatch.reset/0)
    repo = "repo-#{System.unique_integer([:positive])}"
    {:ok, repo: repo}
  end

  defp active_for(repo), do: Enum.filter(Alerts.active(), &(&1.key == "#{repo}|#{@image}"))

  test "no alert before the threshold, an alert naming repo, digest and first line at it", %{
    repo: repo
  } do
    for _ <- 1..2, do: DepsSeedWatch.failed(repo, @image, @reason, workspace_id: "ws-x")
    assert active_for(repo) == []

    DepsSeedWatch.failed(repo, @image, @reason, workspace_id: "ws-x")
    assert [alert] = active_for(repo)
    assert alert.kind == :deps_seed_failing
    assert alert.detail =~ repo
    assert alert.detail =~ @image
    assert alert.detail =~ "DATABASE_URL is not set"
    refute alert.detail =~ "stacktrace line"
  end

  test "the warning is logged once per digest+error, not per spawn", %{repo: repo} do
    log =
      capture_log(fn ->
        for _ <- 1..5, do: DepsSeedWatch.failed(repo, @image, @reason, [])
      end)

    assert length(String.split(log, "DATABASE_URL is not set")) - 1 == 1

    log2 =
      capture_log(fn ->
        DepsSeedWatch.failed(repo, @image, {:seed_failed, 1, "different error"}, [])
      end)

    assert log2 =~ "different error"
  end

  test "a successful seed clears the alert and resets the count", %{repo: repo} do
    for _ <- 1..3, do: DepsSeedWatch.failed(repo, @image, @reason, [])
    assert [_] = active_for(repo)

    DepsSeedWatch.succeeded(repo, @image)
    assert active_for(repo) == []
  end
end
