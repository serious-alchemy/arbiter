defmodule Arbiter.Worker.WatchdogUnrunPipelineTest do
  @moduledoc """
  A `:ci_failed` head whose pipeline the forge refused to run (a GitLab pipeline
  `failed` with zero jobs — e.g. the pushing user is not identity-verified) is not
  a code failure: the Watchdog dispatches no fix pass, spends no attempt, and
  raises an attention item carrying the forge's own reason. A red head with real
  failed jobs is unchanged.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Issue
  alias Arbiter.Test.StubFixPassDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker.Watchdog

  @docs_diff "diff --git a/docs/guide.md b/docs/guide.md\n--- a/docs/guide.md\n+++ b/docs/guide.md\n@@ -1 +1 @@\n-a\n+b\n"

  @unverified %{
    pipeline_id: 99,
    sha: "h1",
    user: "seriousalchemy",
    failure_reason: "The pipeline failed due to the user not being verified.",
    error_messages: "Identity verification is required in order to run CI jobs",
    verification?: true
  }

  setup do
    StubMerger.reset()
    StubFixPassDispatcher.reset()
    :ok
  end

  defp workspace do
    Ash.create!(Arbiter.Tasks.Workspace, %{
      name: "ws-#{System.unique_integer([:positive])}",
      prefix: "up#{System.unique_integer([:positive])}",
      config: %{
        "git_credentials" => %{
          "repos" => %{
            "vstim" => %{"kind" => "gitlab_bot_token", "secret" => "GITLAB_BOT"}
          }
        }
      }
    })
  end

  defp task(ws) do
    Ash.create!(Issue, %{
      title: "unrun",
      description: "body",
      workspace_id: ws.id,
      repo: "vstim"
    })
  end

  defp red(head),
    do: %{
      status: :open,
      approved: true,
      block_reason: :ci_failed,
      pipeline: :failed,
      head_sha: head,
      base_ref: "main"
    }

  defp start(task, ws, ref) do
    StubMerger.set_diff(ref, nil, @docs_diff)

    {:ok, pid} =
      Watchdog.start(
        task_id: task.id,
        mr_ref: ref,
        adapter: StubMerger,
        workspace: ws,
        repo: task.repo,
        auto_merge: true,
        interval_ms: 15,
        initial_delay_ms: 0,
        fix_pass_history: fn _task_id, _mr_ref -> 0 end,
        fix_pass_dispatcher: StubFixPassDispatcher
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    pid
  end

  defp attention(ws), do: Message.inbox("admiral", workspace_id: ws.id)

  test "a zero-job failed pipeline dispatches no fix pass, spends no attempt, and raises attention" do
    ws = workspace()
    t = task(ws)
    StubMerger.queue_get("!up1", List.duplicate(red("h1"), 8))
    StubMerger.set_unrun_pipeline("!up1", @unverified)

    pid = start(t, ws, "!up1")

    wait_until(fn -> attention(ws) != [] end)
    wait_until(fn -> StubMerger.get_count("!up1") >= 4 end)

    assert StubFixPassDispatcher.call_count() == 0
    assert :sys.get_state(pid).auto_resolve_attempts == 0
    assert :sys.get_state(pid).fix_passes_dispatched == 0

    assert [escalation] = attention(ws)
    assert escalation.body =~ "The pipeline failed due to the user not being verified."
    assert escalation.body =~ "Identity verification is required in order to run CI jobs"
    assert escalation.body =~ "seriousalchemy"
    assert escalation.body =~ "git_credentials.repos.vstim (gitlab_bot_token, secret GITLAB_BOT)"
  end

  test "a red head with real failed jobs still gets its fix pass, and no attention item" do
    ws = workspace()
    t = task(ws)
    StubMerger.queue_get("!up2", [red("h1")])

    StubMerger.set_failing_checks("!up2", [
      %{name: "rspec", summary: "1 failure in lib/a.ex", conclusion: "failure"}
    ])

    start(t, ws, "!up2")

    wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
    assert attention(ws) == []
  end

  defp wait_until(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      cond do
        fun.() ->
          :done

        System.monotonic_time(:millisecond) > deadline ->
          flunk("condition not met within timeout")

        true ->
          Process.sleep(10)
          :again
      end
    end)
    |> Enum.find(&(&1 == :done))
  end
end
