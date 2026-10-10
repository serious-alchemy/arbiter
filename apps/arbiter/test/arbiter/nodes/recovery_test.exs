defmodule Arbiter.Nodes.RecoveryTest do
  @moduledoc """
  RW12 (`docs/design/remote-workers.md` §10.5): `Nodes.Recovery.await/1`, the first
  step of the boot sweep. It waits (bounded, in parallel across nodes) for the
  nodes that hold live remote runs to reconnect and deliver what they retained,
  and stamps the runs of a node that never comes back `interrupted` / `:node_lost`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Recovery, Registry, Session}
  alias Arbiter.Workers.Run

  @version "1.2.3"
  @moduletag :tmp_dir

  setup %{tmp_dir: home} do
    prev_version = Application.fetch_env(:arbiter, :node_primary_version)
    Application.put_env(:arbiter, :node_primary_version, @version)
    prev_dir = Application.fetch_env(:arbiter, :data_dir)
    Application.put_env(:arbiter, :data_dir, home)

    on_exit(fn ->
      restore(:node_primary_version, prev_version)
      restore(:data_dir, prev_dir)

      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())
    :ok
  end

  defp restore(key, {:ok, v}), do: Application.put_env(:arbiter, key, v)
  defp restore(key, :error), do: Application.delete_env(:arbiter, key)

  defp enroll!(name) do
    {:ok, %{token: token}} = Nodes.mint_join_token([name: name], "operator:test")
    {:ok, %{node: node}} = Nodes.redeem_join_token(token)
    node
  end

  defp hello(retained) do
    %{
      "agent_version" => @version,
      "proto" => 1,
      "caps" => %{},
      "capacity" => %{"suggestion" => 4},
      "inventory" => %{"runs" => [], "retained" => Enum.map(retained, &%{"run" => &1})}
    }
  end

  defp attach(node, retained, channel \\ self()) do
    Registry.attach(node, channel, hello(retained), tick_ms: :infinity)
  end

  defp run!(node, state \\ :working) do
    Ash.create!(Run, %{
      task_id: "bd-rec-#{System.unique_integer([:positive])}",
      base_task_id: "bd-rec",
      repo: "trib/repo",
      kind: :implement,
      provider: "claude",
      state: state,
      node_id: node && node.id,
      started_at: DateTime.utc_now()
    })
  end

  defp context_fun(_run), do: {:ok, %{home: "/h", branch: "b", base: "main", seeded_paths: []}}

  # Plays an agent: connects after `delay_ms` (as one does after a primary restart, once
  # its backoff elapses) with `retained`, then answers every `recover` the session asks.
  defp start_agent(
         node,
         retained,
         delay_ms \\ 0,
         reply \\ %{"transcripts" => "none", "checkout" => "ok"}
       ) do
    spawn_link(fn ->
      Process.sleep(delay_ms)
      {:ok, %{pid: pid}} = attach(node, retained, self())
      answer_loop(pid, reply)
    end)
  end

  defp answer_loop(pid, reply) do
    receive do
      {:node_session, {:push, "recover", %{"run" => run}}} ->
        Session.checkout_done(pid, run, {:ok, %{head: "tip-of-#{run}"}})
        Session.node_event(pid, "recovered", Map.put(reply, "run", run))
        answer_loop(pid, reply)

      _other ->
        answer_loop(pid, reply)
    end
  end

  defp opts(extra \\ []),
    do:
      Keyword.merge(
        [
          context_fun: &context_fun/1,
          node_timeout_ms: 300,
          total_timeout_ms: 600,
          primary?: true
        ],
        extra
      )

  defp reload(run), do: Ash.get!(Run, run.id)

  test "nothing to recover returns at once" do
    _local = run!(nil)
    _done = run!(enroll!("n0"), :finished)
    assert {:ok, report} = Recovery.await(opts())
    assert report == %{}
  end

  test "a non-primary instance recovers nothing" do
    run!(enroll!("n0"))
    assert {:ok, :skipped} = Recovery.await(opts(primary?: false))
  end

  test "a node that reconnects delivers its retained run before await returns" do
    node = enroll!("n1")
    run = run!(node)
    # connects only after await has started waiting
    start_agent(node, [run.id], 80)

    assert {:ok, report} = Recovery.await(opts(node_timeout_ms: 2_000, total_timeout_ms: 3_000))
    assert report[run.id] == :collected
    # nothing was stamped: the Reconciler (which runs next) resumes it like any interrupted run
    assert reload(run).state == :working
  end

  test "several runs on one node are all recovered" do
    node = enroll!("n3")
    runs = [run!(node), run!(node)]
    start_agent(node, Enum.map(runs, & &1.id))

    assert {:ok, report} = Recovery.await(opts(node_timeout_ms: 2_000, total_timeout_ms: 3_000))
    assert Enum.all?(runs, &(report[&1.id] == :collected))
  end

  test "a node that never reconnects: the run is interrupted as :node_lost, within the budget" do
    node = enroll!("gone")
    run = run!(node)
    started = System.monotonic_time(:millisecond)

    assert {:ok, report} = Recovery.await(opts())
    assert {:unreachable, :timeout} = report[run.id]
    assert System.monotonic_time(:millisecond) - started < 2_000

    updated = reload(run)
    assert updated.state == :finished
    assert updated.outcome == :interrupted
    assert updated.stop_category == "node_lost"
    assert updated.failure_reason =~ "node lost: gone"
    assert updated.completed_at
  end

  test "a node task that overruns the whole budget is killed and its run is node_lost, not unaccounted for" do
    node = enroll!("wedged")
    run = run!(node)
    start_agent(node, [run.id])

    # the context lookup never returns: only the backstop in `await/1` ends the node's task
    wedged = fn _run ->
      receive do
        :never -> :ok
      end
    end

    assert {:ok, report} = Recovery.await(opts(context_fun: wedged))
    assert {:unreachable, :timeout} = report[run.id]
    assert %{state: :finished, outcome: :interrupted, stop_category: "node_lost"} = reload(run)
    assert Recovery.unsettled(report) == []
  end

  test "many unreachable nodes are waited for in parallel, inside the total budget" do
    runs = for i <- 1..4, do: run!(enroll!("gone-#{i}"))
    started = System.monotonic_time(:millisecond)

    assert {:ok, report} = Recovery.await(opts(node_timeout_ms: 400, total_timeout_ms: 800))
    assert Enum.all?(runs, &match?({:unreachable, _}, report[&1.id]))
    assert System.monotonic_time(:millisecond) - started < 1_500
  end

  test "a reachable node that has nothing for the run leaves the row to the Reconciler" do
    node = enroll!("empty")
    run = run!(node)
    {:ok, _} = attach(node, [])

    assert {:ok, report} = Recovery.await(opts())
    assert {:unreachable, :not_on_node} = report[run.id]

    # the node is fine; only the work is missing: it is "server restarted", not node_lost
    untouched = reload(run)
    assert untouched.state == :working
  end

  # bd-4p1vui (docs/design/remote-workers.md §10.4.3, §10.4.6): adoption first, and the
  # collect fallback exactly once whenever adoption does not happen.
  describe "adoption" do
    alias Arbiter.Nodes.Adoption
    alias Arbiter.Worker
    alias Arbiter.Worker.ClaudeSession
    alias Arbiter.Worker.Executor.Node, as: Executor

    @adopt_caps %{"run_hold" => "quiesce", "run_adopt" => "attach"}

    defp running(run_ids) do
      for id <- run_ids, do: %{"id" => id, "state" => "running", "exited" => false, "acked" => 0}
    end

    # Plays an agent that held `runs` across the restart: answers `adopt` per `modes`
    # (`:accept`, `:refuse` or `:silent`), and quiesces and hands over on request. It tells
    # the test what it was asked: `{:agent_saw, event, run}`.
    defp start_holding_agent(node, runs, modes \\ %{}, caps \\ @adopt_caps) do
      test = self()

      spawn_link(fn ->
        hello = %{
          "agent_version" => @version,
          "proto" => 1,
          "caps" => caps,
          "capacity" => %{"suggestion" => 4},
          "inventory" => %{"runs" => running(Enum.map(runs, & &1.id)), "retained" => []}
        }

        {:ok, %{pid: pid}} = Registry.attach(node, self(), hello, tick_ms: :infinity)
        send(test, {:agent_up, pid})
        holding_loop(pid, test, modes)
      end)

      assert_receive {:agent_up, pid}, 2_000
      pid
    end

    defp holding_loop(pid, test, modes) do
      receive do
        {:node_session, {:push, event, %{"run" => run}}}
        when event in ~w(adopt quiesce recover cancel) ->
          send(test, {:agent_saw, event, run})
          answer(pid, event, run, Map.get(modes, run, :accept))
          holding_loop(pid, test, modes)

        _other ->
          holding_loop(pid, test, modes)
      end
    end

    defp answer(pid, "adopt", run, :accept),
      do: Session.node_event(pid, "run.ready", %{"run" => run, "adopted" => true, "acked" => 0})

    defp answer(pid, "adopt", run, :refuse),
      do: Session.node_event(pid, "adopt.refused", %{"run" => run, "reason" => "exited"})

    defp answer(_pid, "adopt", _run, :silent), do: :ok

    defp answer(pid, "quiesce", run, _mode),
      do:
        Session.node_event(pid, "retained", %{"run" => run, "task" => "bd-x", "checkout" => nil})

    defp answer(pid, "recover", run, _mode) do
      Session.checkout_done(pid, run, {:ok, %{head: "tip"}})

      Session.node_event(pid, "recovered", %{
        "run" => run,
        "transcripts" => "none",
        "checkout" => "ok"
      })
    end

    defp answer(_pid, _event, _run, _mode), do: :ok

    # The Worker side of an adoption, as `Dispatch.adopt/2` drives it, minus the ticket: a
    # Worker started to adopt the run, which gets the handle the node hands over.
    defp worker_adopt(node, then_fail? \\ false) do
      fn %Run{} = run, attempt_opts ->
        {:ok, w} =
          Worker.start(
            task_id: run.task_id,
            repo: "arbiter",
            meta: %{adopt: Adoption.adopt_info(run)}
          )

        case Executor.adopt(node.id, %{"run" => run.id, "bridges" => []},
               owner: w,
               adopt_timeout_ms: Keyword.get(attempt_opts, :adopt_timeout_ms)
             ) do
          {:ok, %{handle: handle, stdout_start: start}} ->
            args = %{
              exec: "claude",
              argv: ["claude"],
              cd: System.tmp_dir!(),
              env: [],
              remote: %{
                node: node.id,
                request: %{},
                run_id: run.id,
                prepared: handle,
                stdout_start: start
              }
            }

            config =
              ClaudeSession.build_session_config(run.task_id, nil,
                provider: "claude",
                redact_values: [],
                argv: ["claude"]
              )

            {:ok, ^handle} = GenServer.call(w, {:__claude_session_open__, args, config})

            if then_fail? do
              :ok = Worker.abandon_adoption(w)
              {:error, :failed_after_adopting}
            else
              {:ok, %{worker_pid: w}}
            end

          {:error, reason} ->
            :ok = Worker.abandon_adoption(w)
            {:error, reason}
        end
      end
    end

    defp adopt_opts(extra),
      do:
        opts(
          Keyword.merge([node_timeout_ms: 3_000, total_timeout_ms: 4_000, adopt?: true], extra)
        )

    defp saw(event, run) do
      receive do
        {:agent_saw, ^event, ^run} -> true
      after
        0 -> false
      end
    end

    defp stop_worker(task_id) do
      case Worker.whereis(task_id) do
        nil -> :ok
        pid -> Worker.stop(pid, :normal)
      end
    end

    test "a held run is adopted, not collected: same row, a live Worker, nothing quiesced" do
      node = enroll!("adopt-ok")
      run = run!(node)
      on_exit(fn -> stop_worker(run.task_id) end)
      start_holding_agent(node, [run])

      assert {:ok, report} = Recovery.await(adopt_opts(adopt_fun: worker_adopt(node)))
      assert report == %{run.id => :adopted}

      assert saw("adopt", run.id)
      refute saw("quiesce", run.id)
      refute saw("recover", run.id)
      refute saw("cancel", run.id)

      assert %{state: :working, outcome: nil} = reload(run)
      assert %{run_id: run_id} = Worker.state(Worker.whereis(run.task_id))
      assert run_id == run.id
      assert Recovery.unsettled(report) == []
    end

    for {label, mode, then_fail?} <- [
          {"the agent refuses it (F3)", :refuse, false},
          {"the agent never answers (F6)", :silent, false},
          {"a step after the session adopted fails (F7)", :accept, true}
        ] do
      test "when #{label}, the run is collected exactly once and nothing is cancelled" do
        node = enroll!("adopt-#{unquote(mode)}")
        run = run!(node)
        start_holding_agent(node, [run], %{run.id => unquote(mode)})

        adopt = worker_adopt(node, unquote(then_fail?))
        # the node's answer gets 200 ms, well inside the adoption's own deadline (F6 is the
        # session's timer, not that deadline)
        fun = fn run, o -> adopt.(run, Keyword.put(o, :adopt_timeout_ms, 200)) end
        assert {:ok, report} = Recovery.await(adopt_opts(adopt_fun: fun))
        assert report == %{run.id => :collected}

        assert saw("adopt", run.id)
        assert saw("quiesce", run.id)
        refute saw("quiesce", run.id)
        assert saw("recover", run.id)
        refute saw("recover", run.id)
        refute saw("cancel", run.id)

        # the row is the Reconciler's, as for any collected run
        assert %{state: :working, outcome: nil, stdout_offset: nil} = reload(run)
      end
    end

    test "when the adopt function fails before anything was adopted (F5), the run is collected once" do
      node = enroll!("adopt-f5")
      run = run!(node)
      start_holding_agent(node, [run])

      assert {:ok, report} =
               Recovery.await(adopt_opts(adopt_fun: fn _run, _ -> {:error, :boom} end))

      assert report == %{run.id => :collected}
      refute saw("adopt", run.id)
      assert saw("quiesce", run.id)
      refute saw("quiesce", run.id)
      assert saw("recover", run.id)
    end

    defp never_adopt do
      test = self()

      fn run, _ ->
        send(test, {:adopt_called, run.id})
        {:error, :not_expected}
      end
    end

    test "with adoption switched off (the kill switch), the run is collected and nothing is adopted" do
      node = enroll!("adopt-off")
      run = run!(node)
      start_holding_agent(node, [run])

      assert {:ok, report} = Recovery.await(adopt_opts(adopt_fun: never_adopt(), adopt?: false))
      assert report == %{run.id => :collected}
      refute_received {:adopt_called, _}
      refute saw("adopt", run.id)
    end

    test "the kill switch is config :arbiter, :node_run_adoption" do
      previous = Application.fetch_env(:arbiter, :node_run_adoption)
      Application.put_env(:arbiter, :node_run_adoption, false)
      on_exit(fn -> restore(:node_run_adoption, previous) end)

      node = enroll!("adopt-config-off")
      run = run!(node)
      start_holding_agent(node, [run])

      opts = adopt_opts(adopt_fun: never_adopt()) |> Keyword.delete(:adopt?)
      assert {:ok, report} = Recovery.await(opts)
      assert report == %{run.id => :collected}
      refute_received {:adopt_called, _}
    end

    test "an agent that cannot adopt (no caps.run_adopt) has its run collected" do
      node = enroll!("adopt-older")
      run = run!(node)
      start_holding_agent(node, [run], %{}, %{"run_hold" => "quiesce"})

      assert {:ok, report} = Recovery.await(adopt_opts(adopt_fun: never_adopt()))
      assert report == %{run.id => :collected}
      refute_received {:adopt_called, _}
    end

    test "a run that is not the ticket's own (a reviewer) is collected, not adopted" do
      node = enroll!("adopt-review")

      review_run =
        Ash.create!(Run, %{
          task_id: "bd-rec-review-#{System.unique_integer([:positive])}",
          base_task_id: "bd-rec-review",
          repo: "trib/repo",
          kind: :review,
          role: "review",
          provider: "claude",
          state: :working,
          node_id: node.id,
          started_at: DateTime.utc_now()
        })

      start_holding_agent(node, [review_run])

      assert {:ok, report} = Recovery.await(adopt_opts(adopt_fun: never_adopt()))
      assert report == %{review_run.id => :collected}
      refute_received {:adopt_called, _}
    end

    test "the budget backstop leaves an adopted run alone and stamps only the one it cut off" do
      node = enroll!("adopt-backstop")
      adopted = run!(node)
      wedged = run!(node)
      on_exit(fn -> stop_worker(adopted.task_id) end)
      start_holding_agent(node, [adopted, wedged])

      adopt = worker_adopt(node)

      fun = fn
        %Run{id: id} = run, o when id == adopted.id -> adopt.(run, o)
        _other, _o -> {:error, :not_this_one}
      end

      # the other run's collect never returns: only the backstop ends the node's task
      context = fn
        %Run{id: id} when id == wedged.id ->
          receive do
            :never -> :ok
          end

        run ->
          context_fun(run)
      end

      assert {:ok, report} =
               Recovery.await(
                 opts(
                   node_timeout_ms: 1_500,
                   total_timeout_ms: 1_500,
                   adopt_fun: fun,
                   context_fun: context
                 )
               )

      assert report[adopted.id] == :adopted
      assert {:unreachable, :timeout} = report[wedged.id]
      assert %{state: :working, outcome: nil} = reload(adopted)
      assert %{state: :finished, stop_category: "node_lost"} = reload(wedged)
    end

    # §10.4.6 F12: the deadline holds the whole adoption, not only the node's answer
    # (egress, the image plan and its publication come before the node is asked).
    test "an adopter that started its Worker and then wedged is cut off: no Worker is left, the run is collected once" do
      node = enroll!("adopt-wedged")
      run = run!(node)
      start_holding_agent(node, [run])
      test = self()

      wedged = fn %Run{} = run, _o ->
        {:ok, w} =
          Worker.start(
            task_id: run.task_id,
            repo: "arbiter",
            meta: %{adopt: Adoption.adopt_info(run)}
          )

        send(test, {:adopter, w})

        receive do
          :never -> :ok
        end
      end

      # the deadline is half the node's budget: about 1.5 s, and the collect has the rest
      assert {:ok, report} = Recovery.await(adopt_opts(adopt_fun: wedged))
      assert report == %{run.id => :collected}

      assert_received {:adopter, w}
      ref = Process.monitor(w)
      assert_receive {:DOWN, ^ref, :process, ^w, _}
      assert Worker.whereis(run.task_id) == nil

      refute saw("adopt", run.id)
      assert saw("quiesce", run.id)
      refute saw("quiesce", run.id)
      assert saw("recover", run.id)
      refute saw("recover", run.id)
      refute saw("cancel", run.id)
      assert %{state: :working, outcome: nil, stdout_offset: nil} = reload(run)
      assert Recovery.unsettled(report) == []
    end

    test "an adoption still waiting on the node at its deadline is undone without a cancel and collected once" do
      node = enroll!("adopt-slow-node")
      run = run!(node)
      start_holding_agent(node, [run], %{run.id => :silent})

      # the node's own answer may take far longer than the adoption as a whole
      adopt = worker_adopt(node)
      patient = fn run, o -> adopt.(run, Keyword.put(o, :adopt_timeout_ms, 60_000)) end

      assert {:ok, report} = Recovery.await(adopt_opts(adopt_fun: patient))
      assert report == %{run.id => :collected}
      assert Worker.whereis(run.task_id) == nil

      assert saw("adopt", run.id)
      assert saw("quiesce", run.id)
      refute saw("quiesce", run.id)
      assert saw("recover", run.id)
      refute saw("recover", run.id)
      refute saw("cancel", run.id)
      assert %{state: :working, outcome: nil, stdout_offset: nil} = reload(run)
    end

    test "an adopter whose Worker's session attached the run is let finish, and the backstop leaves the run adopted" do
      node = enroll!("adopt-attached")
      run = run!(node)
      on_exit(fn -> stop_worker(run.task_id) end)
      start_holding_agent(node, [run])
      adopt = worker_adopt(node)

      # the session attached the run; what is left (the machine, the driver) never returns
      fun = fn run, o ->
        {:ok, _} = adopt.(run, o)

        receive do
          :never -> :ok
        end
      end

      # the deadline (about 0.75 s) finds the run attached and waits; the backstop ends it
      assert {:ok, report} =
               Recovery.await(
                 adopt_opts(adopt_fun: fun, node_timeout_ms: 1_500, total_timeout_ms: 1_500)
               )

      assert report == %{run.id => :adopted}
      assert saw("adopt", run.id)
      refute saw("quiesce", run.id)
      refute saw("cancel", run.id)

      assert %{state: :working, outcome: nil} = reload(run)
      assert %{run_id: run_id} = Worker.state(Worker.whereis(run.task_id))
      assert run_id == run.id
    end
  end

  test "a run whose home clone is missing is not asked for" do
    node = enroll!("n2")
    run = run!(node)
    {:ok, _} = attach(node, [run.id])

    assert {:ok, report} =
             Recovery.await(opts(context_fun: fn _ -> {:error, :no_home_clone} end))

    assert {:unreachable, {:no_context, :no_home_clone}} = report[run.id]
    refute_received {:node_session, {:push, "recover", _}}
  end
end
