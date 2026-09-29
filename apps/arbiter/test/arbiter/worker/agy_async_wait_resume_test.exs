defmodule Arbiter.Worker.AgyAsyncWaitResumeTest do
  @moduledoc """
  bd-bxwsvo: on agy 1.2.12 ending a turn while a background task runs is the
  correct way to wait — the CLI keeps the session alive (up to 30m) and wakes
  the agent with a completion system message. The one abandoned wait left is
  the CLI giving up at that cap and killing the task on exit. When that
  happens the worker must resume the SAME agy conversation with agy's own
  correction (narrow the command, never poll), not the Claude text about
  `Monitor` / `TaskOutput` / the `Bash` timeout.

  Drives a real `Worker` + port with a stub `agy` script. The first run's
  stream is synthetic but uses agy's real wire shapes: the stream-json events
  from the bd-bxwsvo probe, and the two stderr lines verbatim from agy
  1.2.12's own log ("root agent idle; waiting up to 30m0s …",
  "terminating N background task(s) on exit").
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession

  @conversation_id "0b9d2c4e-7a51-4f0e-9b1e-bx0000000001"

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "agy-async-ws-#{System.unique_integer([:positive])}",
        prefix: "aa",
        config: %{}
      })

    dir = Path.join(System.tmp_dir!(), "agy-async-#{System.unique_integer([:positive])}")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf(dir) end)

    first_run =
      [
        %{
          "event" => "init",
          "conversation_id" => @conversation_id,
          "init" => %{"cwd" => dir, "model" => "gemini-3.8-flash-low"}
        },
        %{
          "event" => "step_update",
          "step_update" => %{
            "conversation_id" => @conversation_id,
            "step_index" => 2,
            "state" => "RUNNING",
            "step_type" => "tool",
            "tool_name" => "run_command",
            "tool_info" => %{
              "name" => "run_command",
              "parameters" => %{"CommandLine" => "mix test"},
              "output" =>
                "Tool is running as a background task with task id: " <>
                  "#{@conversation_id}/task-2\n"
            }
          }
        },
        %{
          "event" => "step_update",
          "step_update" => %{
            "conversation_id" => @conversation_id,
            "step_index" => 3,
            "state" => "DONE",
            "step_type" => "agent_response",
            "text_delta" => "I launched `mix test` and will wait for it to finish.\n"
          }
        },
        %{
          "event" => "result",
          "result" => %{
            "conversation_id" => @conversation_id,
            "status" => "SUCCESS",
            "response" => "I launched `mix test` and will wait for it to finish.\n",
            "num_turns" => 1,
            "usage" => %{"total_tokens" => 1234}
          }
        }
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)

    File.write!(Path.join(dir, "first_run.jsonl"), first_run <> "\n")

    # A stub `agy` — never the real CLI (the basename is what makes
    # `Gemini.splice_prompt/2` emit `--conversation`). The first run launches
    # a background task, ends its turn, and is then killed at agy's cap; a
    # `--conversation` resume records its argv, then waits for the test's
    # go-file before printing `arb done`.
    stub = Path.join(bin, "agy")

    File.write!(stub, """
    #!/bin/sh
    case " $* " in
      *" --conversation "*)
        printf '%s\\0' "$@" > '#{dir}/resume_argv'
        i=0
        while [ ! -f '#{dir}/go' ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done
        echo 'arb done'
        exit 0 ;;
      *)
        cat '#{dir}/first_run.jsonl'
        echo 'root agent idle; waiting up to 30m0s for 1 background task(s)' >&2
        echo 'terminating 1 background task(s) on exit' >&2
        exit 0 ;;
    esac
    """)

    File.chmod!(stub, 0o755)
    %{ws: ws, dir: dir, stub: stub}
  end

  defp wait_until(fun, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(25)
        do_wait(fun, deadline)
    end
  end

  test "an agy run killed at the background-wait cap resumes with agy's own correction",
       %{ws: ws, dir: dir, stub: stub} do
    {:ok, task} =
      Ash.create(Issue, %{title: "agy async probe", workspace_id: ws.id, issue_type: :research})

    {:ok, task} = Ash.update(task, %{status: :in_progress})

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "unknown",
        workspace_id: ws.id,
        meta: %{issue_type: :research, review_spawn: false, notes_nudge_cap: 0}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: dir,
        provider: "gemini",
        command: [stub, "-p", "original task prompt", "--output-format", "stream-json"]
      )

    argv_file = Path.join(dir, "resume_argv")
    wait_until(fn -> File.exists?(argv_file) and File.read!(argv_file) =~ @conversation_id end)

    argv = argv_file |> File.read!() |> String.split(<<0>>, trim: true)
    idx = Enum.find_index(argv, &(&1 == "--conversation"))
    assert idx, "resume must continue the SAME agy conversation: #{inspect(argv)}"
    assert Enum.at(argv, idx + 1) == @conversation_id

    prompt = Enum.at(argv, Enum.find_index(argv, &(&1 == "-p")) + 1)
    refute prompt =~ "original task prompt"

    # agy's correction, not Claude's
    assert prompt =~ "30 minutes"
    assert prompt =~ "Do NOT poll"
    refute prompt =~ "TaskOutput"
    refute prompt =~ "Monitor"
    refute prompt =~ "Bash"

    {:ok, _} = Ash.update(task, %{notes: "## Findings\n\nnarrowed the run."}, action: :update)
    File.write!(Path.join(dir, "go"), "")
    wait_until(fn -> match?(%{state: :finished, outcome: :succeeded}, Worker.state(pid)) end)
  end
end
