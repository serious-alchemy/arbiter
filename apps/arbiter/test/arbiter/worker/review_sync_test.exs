defmodule Arbiter.Worker.ReviewSyncTest do
  @moduledoc "bd-8slhrb — the pre-review target-sync thresholds and their config keys."

  use ExUnit.Case, async: true

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.ReviewSync

  defp ws(config), do: %Workspace{id: "w", config: config}

  test "defaults when nothing is configured or the workspace is missing" do
    expected = [max_commits_behind: 100, max_hours_behind: 0]

    assert ReviewSync.opts(ws(%{}), "o/r") == expected
    assert ReviewSync.opts(nil, "o/r") == expected
    assert ReviewSync.default_max_commits_behind() == 100
    assert ReviewSync.default_max_hours_behind() == 0
  end

  test "workspace-wide values, with a repo entry overriding them" do
    config = %{
      "review" => %{
        "max_commits_behind" => 20,
        "max_hours_behind" => "48",
        "repos" => %{"o/r" => %{"max_commits_behind" => 0}}
      }
    }

    assert ReviewSync.opts(ws(config), "o/other") == [
             max_commits_behind: 20,
             max_hours_behind: 48
           ]

    assert ReviewSync.opts(ws(config), "o/r") == [max_commits_behind: 0, max_hours_behind: 48]
  end

  test "unparsable values fall back to the default" do
    config = %{"review" => %{"max_commits_behind" => "lots", "max_hours_behind" => -3}}

    assert ReviewSync.opts(ws(config), nil) == [max_commits_behind: 100, max_hours_behind: 0]
  end
end
