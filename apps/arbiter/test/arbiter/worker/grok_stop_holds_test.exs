defmodule Arbiter.Worker.GrokStopHoldsTest do
  @moduledoc """
  bd-cwq8b0: a grok worker's terminal error, through the real stream parser,
  becomes the right hold — a free-usage-exhausted 429 a quota hold that lifts as
  the rolling 24h drains, a login failure an auth hold (never a quota hold).
  """
  # DataCase (async: false → shared sandbox): the worker runs under the
  # DynamicSupervisor and writes its Run row.
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.AuthHold
  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Agents.Grok
  alias Arbiter.Agents.GrokRouting
  alias Arbiter.Agents.Routing
  alias Arbiter.Quota.GrokLedger
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.StopReason
  alias Arbiter.Workers.Run
  alias Arbiter.Usage.Event

  require Ash.Query

  @moduletag :capture_log

  @exhausted "API error (status 429 Too Many Requests): subscription:free-usage-exhausted: " <>
               "You've used all the included free usage for model grok-4.7 for now. Usage " <>
               "resets over a rolling 24-hour window — tokens (actual/limit): 604183/500000."

  setup do
    prev = Application.get_env(:arbiter, :grok_quota)
    Application.put_env(:arbiter, :grok_quota, cap_tokens: 500_000)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:arbiter, :grok_quota, prev),
        else: Application.delete_env(:arbiter, :grok_quota)
    end)
  end

  # Run a fake grok that prints `events` then exits 1, under a real Worker, and
  # return the finished Run row.
  defp stop_with(errors, opts \\ []) do
    task_id = "bd-grokstop-#{System.unique_integer([:positive])}"
    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-grok")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    cwd = System.tmp_dir!()
    path = Path.join(cwd, "grok-stream-#{System.unique_integer([:positive])}.jsonl")

    File.write!(
      path,
      Enum.map_join(
        [
          %{"type" => "system", "subtype" => "init", "session_id" => "", "model" => "grok-4.7"},
          %{
            "type" => "result",
            "subtype" => "error_during_execution",
            "is_error" => true,
            "num_turns" => 0,
            "errors" => errors,
            "usage" => %{}
          }
        ],
        "\n",
        &Jason.encode!/1
      ) <> "\n"
    )

    if Keyword.get(opts, :routed?, false),
      do: Worker.report(pid, :routing_config, %{provider: "grok"})

    :ok = Worker.advance(pid, :implement)

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: cwd,
        provider: "grok",
        command: ["sh", "-c", "cat #{path}; exit 1"]
      )

    wait_for(fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end)

    [run] = Run |> Ash.Query.filter(task_id == ^task_id) |> Ash.read!()
    run
  end

  defp wait_for(fun, tries \\ 150) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("worker never finished")
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end

  test "a free-usage-exhausted 429 records a quota stop and the gate holds on the ledger" do
    # Arbiter's ledger saw 100K of it; the rest was unseen usage.
    Ash.create!(Event, %{
      task_id: "bd-grok-seen",
      source: :task,
      step: :work,
      provider: "grok",
      tokens_in: 100_000,
      occurred_at: DateTime.add(DateTime.utc_now(), -3600, :second)
    })

    assert GrokLedger.snapshot().status == nil

    run = stop_with([@exhausted])

    assert run.stop_category == "quota_exhausted"
    assert run.failure_reason =~ "tokens (actual/limit): 604183/500000"

    assert %{actual: 604_183, limit: 500_000} = GrokLedger.exhaustion()

    snapshot = GrokLedger.snapshot()
    assert snapshot.status == "limit_reached"
    assert {:hold, _} = Arbiter.Quota.Gate.Throttle.check(nil, snapshot, nil, [])
    # Lifts when the window drains (the unseen usage ages out 24h after the
    # 429), not at a fixed time.
    assert DateTime.diff(snapshot.reset_at, DateTime.utc_now(), :hour) in 23..24
  end

  test "'Not signed in' is an auth stop, not a quota hold" do
    run =
      stop_with([
        "Not signed in. To authenticate without a browser, run: grok login --device-code"
      ])

    assert run.stop_category == "auth_expired"
    assert GrokLedger.exhaustion() == nil
    assert GrokLedger.snapshot().status == nil
  end

  test "the first 'Not signed in' death opens the grok AuthHold (bd-8rvkqd)" do
    {:ok, watchdog} =
      start_supervised(%{
        id: make_ref(),
        start: {CredentialWatchdog, :start_link, [[name: nil, enabled: false, adapters: [Grok]]]}
      })

    {:ok, hold} =
      start_supervised(%{
        id: make_ref(),
        start: {AuthHold, :start_link, [[name: nil, credential_watchdog: watchdog]]}
      })

    :ok = CredentialWatchdog.set_auth_hold(hold, watchdog)

    reason =
      StopReason.classify(
        1,
        ["grok error: Not signed in. To authenticate without a browser, run: grok login"],
        "grok"
      )

    assert reason.category == :auth_expired
    assert AuthHold.record_death(Grok, reason, hold) == :opened
    assert AuthHold.open?(Grok, hold)
    assert AuthHold.record_death(Grok, reason, hold) == :held
    assert %{threshold: 1} = AuthHold.status(Grok, hold)
  end

  describe "a grok worker that dies 'Not signed in' at spawn (bd-8rvkqd)" do
    setup do
      # The application singleton: the worker reports to it, the router reads it.
      AuthHold.reset(Grok)
      on_exit(fn -> AuthHold.reset(Grok) end)
    end

    test "opens the grok auth hold at once, and grok is no longer routed to" do
      workspace = %Workspace{
        config: %{
          "agent" => %{"type" => "claude", "config" => %{}},
          "routing" => %{"policy" => "by_difficulty", "grok" => %{"enabled" => true}}
        }
      }

      d1 = %Issue{difficulty: 1}
      assert %{type: :grok} = Routing.choose(d1, workspace, %{})
      refute AuthHold.open?(Grok)

      run =
        stop_with(
          ["Not signed in. To authenticate without a browser, run: grok login --device-code"],
          routed?: true
        )

      assert run.stop_category == "auth_expired"
      assert AuthHold.open?(Grok)
      assert GrokRouting.held?()

      # The reopened ticket (still a D1) routes to the next eligible provider...
      assert %{type: :claude} = Routing.choose(d1, workspace, %{})

      # ...and routing to grok resumes once the hold is cleared.
      AuthHold.reset(Grok)
      assert %{type: :grok} = Routing.choose(d1, workspace, %{})
    end
  end
end
