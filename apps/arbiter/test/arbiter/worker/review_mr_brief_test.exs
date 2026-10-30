defmodule Arbiter.Worker.ReviewMrBriefTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.ReviewMrBrief

  defmodule GitHubStub do
    def get("gh/1"),
      do: {:ok, %{title: "T", body: "Ran the loop 50/50 times, all green.", pipeline: "failed"}}

    def failing_check_logs("gh/1"),
      do:
        {:ok,
         [
           %{
             name: "test (ubuntu)",
             summary: "1) test boom\n  ** (RuntimeError) kaboom",
             conclusion: "failure"
           }
         ]}
  end

  defmodule GitLabStub do
    def get("gl/2"),
      do: {:ok, %{title: "T", body: "Evidence: pipeline 99 green.", pipeline: "success"}}

    def failing_check_logs("gl/2"), do: {:ok, []}
  end

  defmodule BrokenStub do
    def get(_), do: {:error, :forbidden}
    def failing_check_logs(_), do: {:error, :forbidden}
  end

  test "GitHub: description, pipeline status and failed job tail" do
    out = ReviewMrBrief.fetch(nil, nil, GitHubStub, "gh/1")
    assert out =~ "Ran the loop 50/50 times"
    assert out =~ "pipeline: failed"
    assert out =~ "test (ubuntu)"
    assert out =~ "RuntimeError) kaboom"
  end

  test "GitLab: description and a green pipeline with no failed jobs" do
    out = ReviewMrBrief.fetch(nil, nil, GitLabStub, "gl/2")
    assert out =~ "Evidence: pipeline 99 green."
    assert out =~ "pipeline: success"
    assert out =~ "no failed jobs"
  end

  test "forge errors yield an empty brief" do
    assert ReviewMrBrief.fetch(nil, nil, BrokenStub, "x") == ""
  end

  test "no PR ref yields an empty brief" do
    assert ReviewMrBrief.fetch(nil, nil, GitHubStub, nil) == ""
  end

  test "log tails and description are bounded" do
    long = String.duplicate("x", 50_000) <> "TAILEND"

    out =
      ReviewMrBrief.render(%{body: long, pipeline: "failed"}, [
        %{name: "j", summary: long, conclusion: "failure"}
      ])

    assert byte_size(out) < 12_000
    assert out =~ "TAILEND"
  end

  test "instruction tells the reviewer to check the evidence before NOT MET" do
    text = ReviewMrBrief.instruction()
    assert text =~ "MR/PR description"
    assert text =~ "pipeline"
    assert text =~ "NOT MET"
  end
end
