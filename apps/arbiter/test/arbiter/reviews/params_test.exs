defmodule Arbiter.Reviews.ParamsTest do
  use ExUnit.Case, async: true

  alias Arbiter.Reviews.Params

  describe "dispatch_opts/2" do
    test "carries force, follow_up, scope, report_only and tracker_context_* (D-W-6)" do
      args = %{
        "pr" => "octo/widget#42",
        "repo" => "widget",
        "automation" => "report_only",
        "force" => true,
        "follow_up" => "false",
        "report_only" => "1",
        "scope" => "repo",
        "tracker_context_ref" => " PROJ-7 ",
        "tracker_context_type" => "jira"
      }

      assert {:ok, opts} = Params.dispatch_opts(args, workspace: "ws-1", dispatched_by: "x")

      assert opts[:pr] == "octo/widget#42"
      assert opts[:repo] == "widget"
      assert opts[:workspace] == "ws-1"
      assert opts[:dispatched_by] == "x"
      assert opts[:automation] == "report_only"
      assert opts[:force] == true
      assert opts[:follow_up] == false
      assert opts[:report_only] == true
      assert opts[:scope] == "repo"
      assert opts[:tracker_context_ref] == "PROJ-7"
      assert opts[:tracker_context_type] == "jira"
    end

    test "leaves unset flags out so ExternalReview applies its own defaults" do
      assert {:ok, opts} = Params.dispatch_opts(%{"pr" => "1"}, [])

      refute Keyword.has_key?(opts, :force)
      refute Keyword.has_key?(opts, :follow_up)
      refute Keyword.has_key?(opts, :scope)
      refute Keyword.has_key?(opts, :report_only)
    end

    test "a junk flag is invalid, not a silent unset" do
      assert {:error, {:invalid, msg}} = Params.dispatch_opts(%{"force" => "yes"}, [])
      assert msg =~ "force"
      assert {:error, {:invalid, msg}} = Params.dispatch_opts(%{"follow_up" => "maybe"}, [])
      assert msg =~ "follow_up"
    end
  end

  describe "greenlight_opts/2" do
    test "select: omitted, \"all\", a list, and []" do
      assert {:ok, opts} = Params.greenlight_opts("r1", %{})
      assert opts[:record_id] == "r1"
      refute Keyword.has_key?(opts, :select)

      assert {:ok, [select: :all] = _} =
               Params.greenlight_opts("r1", %{"select" => "all"}) |> only(:select)

      assert {:ok, [select: [0, 2]]} =
               Params.greenlight_opts("r1", %{"select" => [0, 2]}) |> only(:select)

      assert {:ok, [select: []]} =
               Params.greenlight_opts("r1", %{"select" => []}) |> only(:select)
    end

    test "rejects a malformed select" do
      for bad <- ["some", [-1], ["0"], 3] do
        assert {:error, {:invalid, msg}} = Params.greenlight_opts("r1", %{"select" => bad})
        assert msg =~ "select"
      end
    end

    test "post_verdict is a tri-state boolean" do
      assert {:ok, opts} = Params.greenlight_opts("r1", %{"post_verdict" => false})
      assert opts[:post_verdict] == false
      assert {:error, {:invalid, _}} = Params.greenlight_opts("r1", %{"post_verdict" => "x"})
    end
  end

  defp only({:ok, opts}, key), do: {:ok, Keyword.take(opts, [key])}
end
