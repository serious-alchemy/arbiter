defmodule Arbiter.Worker.VisualBaselines.ConfigTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.VisualBaselines.Config

  defp ws(worker), do: %{config: %{"worker" => worker}}

  @minimal %{"job" => "visual", "baseline_dir" => "e2e/__snapshots__"}

  describe "resolve/2" do
    test ":none when nothing is configured" do
      assert Config.resolve(nil, "tonic") == :none
      assert Config.resolve(%{config: %{}}, "tonic") == :none
      assert Config.resolve(ws(%{"seed_paths" => []}), "tonic") == :none
    end

    test "reads the per-repo block and fills the defaults" do
      workspace = ws(%{"repos" => %{"tonic" => %{"visual_baselines" => @minimal}}})

      assert {:ok, config} = Config.resolve(workspace, "tonic")
      assert config.job == "visual"
      assert config.baseline_dir == "e2e/__snapshots__"
      assert config.actual_suffix == "-actual.png"
      assert config.baseline_suffix == ".png"
      assert config.artifact_path == ""
      assert config.ignore_paths == []
      assert config.max_snapshots == 50
      assert config.artifact == nil
    end

    test "another repo does not see it" do
      workspace = ws(%{"repos" => %{"tonic" => %{"visual_baselines" => @minimal}}})
      assert Config.resolve(workspace, "other") == :none
    end

    test "a workspace-level block applies to every repo; the repo's keys win" do
      workspace =
        ws(%{
          "visual_baselines" => Map.put(@minimal, "max_snapshots", 10),
          "repos" => %{"tonic" => %{"visual_baselines" => %{"max_snapshots" => 3}}}
        })

      assert {:ok, %{max_snapshots: 3, job: "visual"}} = Config.resolve(workspace, "tonic")
      assert {:ok, %{max_snapshots: 10}} = Config.resolve(workspace, "other")
    end

    test "an invalid block is an error naming the problem, never a silent default" do
      workspace = ws(%{"visual_baselines" => %{"job" => "visual"}})
      assert {:error, msg} = Config.resolve(workspace, "tonic")
      assert msg =~ "baseline_dir"
    end
  end

  describe "validate/1" do
    test "accepts the full shape" do
      assert {:ok, config} =
               Config.validate(%{
                 "job" => "visual",
                 "artifact" => "playwright-actuals",
                 "artifact_path" => "test-results",
                 "actual_suffix" => "-actual.png",
                 "baseline_dir" => "e2e",
                 "baseline_suffix" => "-chromium-linux.png",
                 "ignore_paths" => ["docs/**", "*.md"],
                 "max_snapshots" => 20
               })

      assert config.artifact == "playwright-actuals"
      assert config.ignore_paths == ["docs/**", "*.md"]
    end

    test "rejects a missing job, a missing baseline_dir, escaping paths and bad types" do
      for bad <- [
            %{"baseline_dir" => "e2e"},
            %{"job" => "", "baseline_dir" => "e2e"},
            %{"job" => "v", "baseline_dir" => "/abs"},
            %{"job" => "v", "baseline_dir" => "../up"},
            %{"job" => "v", "baseline_dir" => "e2e", "artifact_path" => "../x"},
            %{"job" => "v", "baseline_dir" => "e2e", "ignore_paths" => "docs"},
            %{"job" => "v", "baseline_dir" => "e2e", "max_snapshots" => 0},
            %{"job" => "v", "baseline_dir" => "e2e", "actual_suffix" => ""},
            "nope"
          ] do
        assert {:error, _} = Config.validate(bad), "expected #{inspect(bad)} to be rejected"
      end
    end
  end
end
