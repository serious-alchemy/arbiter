defmodule Arbiter.Worker.AdoptionTest do
  @moduledoc """
  bd-4p1vui (`docs/design/remote-workers.md` §10.4.3, §10.4.5, §10.4.10): the Worker side of
  adopting a run a node kept across a primary restart. The remote session is handed to the
  Worker the way `ClaudeSession.start/1` does (`:__claude_session_open__` with the placed or
  adopted handle), so no node is needed: the handle is the session's only link to it.

  async: false: the Worker writes its run row from its own process (shared sandbox), the
  global worker registry, and the `:worker_node_stopping_override` flag.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Workers.Run

  require Ash.Query

  defp put_env!(key, value) do
    previous = Application.fetch_env(:arbiter, key)
    Application.put_env(:arbiter, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:arbiter, key, v)
        :error -> Application.delete_env(:arbiter, key)
      end
    end)
  end

  # A private stand-in for `Arbiter.Worker.Supervisor`: stopping it is what the application
  # does to the real one on shutdown.
  defp start_sup!,
    do: start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: :adoption_test_sup)

  defp stop_sup!, do: :ok = stop_supervised(:adoption_test_sup)

  defp start_under!(sup, opts) do
    {:ok, pid} = DynamicSupervisor.start_child(sup, {Worker, opts})
    pid
  end

  defp new_task_id, do: "bd-adopt-#{System.unique_integer([:positive])}"

  # The row a Worker before the restart wrote: live, on a node, its session known.
  defp row!(overrides \\ %{}) do
    task_id = new_task_id()

    Ash.create!(
      Run,
      Map.merge(
        %{
          task_id: task_id,
          base_task_id: task_id,
          repo: "arbiter",
          kind: :implement,
          role: "base",
          provider: "claude",
          state: :working,
          node_id: Ecto.UUID.generate(),
          session_id: "sess-before-restart",
          model: "claude-opus-5-5",
          harness_version: "2.1.300",
          config_dir: "/old/primary/claude-config",
          started_at: DateTime.add(DateTime.utc_now(), -600, :second)
        },
        overrides
      )
    )
  end

  defp adopt_info(%Run{} = row, stdout_offset \\ nil) do
    %{
      run_id: row.id,
      node_id: row.node_id,
      session_id: row.session_id,
      model: row.model,
      harness_version: row.harness_version,
      config_dir: row.config_dir,
      started_at: row.started_at,
      stdout_offset: stdout_offset
    }
  end

  defp port_args(node_id, run_id, handle, stdout_start) do
    %{
      exec: "claude",
      argv: ["claude", "--print", "a prompt never sent"],
      cd: System.tmp_dir!(),
      env: [],
      remote: %{
        node: node_id,
        request: %{},
        run_id: run_id,
        prepared: handle,
        stdout_start: stdout_start
      }
    }
  end

  defp session_config(task_id) do
    ClaudeSession.build_session_config(task_id, nil,
      provider: "claude",
      redact_values: [],
      argv: ["claude"],
      composed_prompt: "a prompt never sent"
    )
  end

  defp open!(pid, node_id, run_id, stdout_start \\ 0) do
    handle = {:remote, {node_id, run_id, make_ref()}}
    args = port_args(node_id, run_id, handle, stdout_start)

    assert {:ok, ^handle} =
             GenServer.call(pid, {:__claude_session_open__, args, session_config(task_of(pid))})

    handle
  end

  defp task_of(pid), do: Worker.state(pid).task_id

  defp rows_for(task_id),
    do: Run |> Ash.Query.filter(task_id == ^task_id) |> Ash.read!() |> Enum.map(& &1.id)

  defp registry_entry(task_id),
    do: Enum.find(Arbiter.Worker.Registry.live_dispatches(), &(&1.registry_key == task_id))

  describe "an adopting Worker" do
    test "takes the run's row over: no new row, no hand-off, its run id once the session opens" do
      row = row!()
      task_id = row.task_id
      node_id = row.node_id

      {:ok, pid} =
        Worker.start(task_id: task_id, repo: "arbiter", meta: %{adopt: adopt_info(row)})

      on_exit(fn -> if Process.alive?(pid), do: Worker.abandon_adoption(pid) end)

      snap = Worker.state(pid)
      assert snap.run_id == nil
      assert snap.state == :starting
      assert DateTime.compare(snap.started_at, row.started_at) == :eq
      assert rows_for(task_id) == [row.id]

      # §10.4.10: its registry entry names the node from the start
      assert %{node_id: ^node_id} = registry_entry(task_id)

      # what Dispatch reports before the session opens is not written over the row
      :ok = Worker.report(pid, :run_provenance, %{routing_policy: "rewritten by the adoption"})

      _handle = open!(pid, node_id, row.id)

      snap = Worker.state(pid)
      assert snap.run_id == row.id
      assert %{run_id: adopted_id, node_id: ^node_id} = snap.meta.adopted
      assert adopted_id == row.id
      refute Map.has_key?(snap.meta, :adopt)
      # the session is seeded from the row: the usage ledger keeps the same session id
      assert snap.meta.session_id == "sess-before-restart"
      assert snap.meta.config_dir == "/old/primary/claude-config"

      after_open = Ash.get!(Run, row.id)
      assert after_open.state == :working
      assert after_open.outcome == nil
      assert after_open.routing_policy == nil
      # the prompt it built was never sent: nothing recorded as what the run was told
      assert after_open.prompt_sha256 == nil
      assert after_open.config_dir == "/old/primary/claude-config"
      assert after_open.node_id == node_id
      assert rows_for(task_id) == [row.id]
      assert %{node_id: ^node_id} = registry_entry(task_id)
    end

    # §10.4.10 and DC4: the node comes from the adoption, the seat (account, pool) from the
    # workspace's provider account, both in `init/1`; the session open re-stamps neither away.
    test "stamps its registry entry with the adoption's node and its seat from the start" do
      account =
        Ash.create!(ProviderAccount, %{
          provider: :claude,
          slug: "adopt-seat-#{System.unique_integer([:positive])}"
        })

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "adopt-seat-#{System.unique_integer([:positive])}",
          prefix: "as#{System.unique_integer([:positive])}"
        })

      Ash.create!(WorkspaceProviderAccount, %{
        workspace_id: ws.id,
        provider: :claude,
        provider_account_id: account.id
      })

      row = row!()
      task_id = row.task_id
      node_id = row.node_id
      account_id = account.id

      # the meta `Dispatch.adopt/2` builds: its `agent_type: :claude` is the provider
      {:ok, pid} =
        Worker.start(
          task_id: task_id,
          repo: "arbiter",
          workspace_id: ws.id,
          meta: %{adopt: adopt_info(row), provider: "claude"}
        )

      on_exit(fn -> if Process.alive?(pid), do: Worker.abandon_adoption(pid) end)

      assert %{node_id: ^node_id, provider: "claude", account_id: ^account_id, pool: "claude"} =
               registry_entry(task_id)

      _handle = open!(pid, node_id, row.id)

      assert %{node_id: ^node_id, provider: "claude", account_id: ^account_id, pool: "claude"} =
               registry_entry(task_id)
    end

    test "abandon_adoption gives up without writing the row, after the session opened or before" do
      for open? <- [true, false] do
        row = row!()

        {:ok, pid} =
          Worker.start(task_id: row.task_id, repo: "arbiter", meta: %{adopt: adopt_info(row)})

        if open?, do: open!(pid, row.node_id, row.id)

        ref = Process.monitor(pid)
        assert :ok = Worker.abandon_adoption(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

        untouched = Ash.get!(Run, row.id)
        assert untouched.state == :working
        assert untouched.outcome == nil
        assert untouched.completed_at == nil
        assert untouched.stdout_offset == nil
        assert Worker.whereis(row.task_id) == nil
      end
    end

    # §10.4.6 F12: what undoes an adoption whose caller was cut off.
    test "abandon_adoption/2 gives up only an adoption no session has attached" do
      row = row!()

      {:ok, pid} =
        Worker.start(task_id: row.task_id, repo: "arbiter", meta: %{adopt: adopt_info(row)})

      on_exit(fn -> if Process.alive?(pid), do: Worker.abandon_adoption(pid) end)

      assert {:error, :not_adopting} = Worker.abandon_adoption(pid, Ecto.UUID.generate())
      _handle = open!(pid, row.node_id, row.id)

      # attached: the Worker owns the run and keeps it
      assert {:error, :attached} = Worker.abandon_adoption(pid, row.id)
      assert %{run_id: run_id} = Worker.state(pid)
      assert run_id == row.id

      # not attached yet: given up as abandon_adoption/1 does, the row untouched
      other = row!()

      {:ok, adopting} =
        Worker.start(task_id: other.task_id, repo: "arbiter", meta: %{adopt: adopt_info(other)})

      ref = Process.monitor(adopting)
      assert :ok = Worker.abandon_adoption(adopting, other.id)
      assert_receive {:DOWN, ^ref, :process, ^adopting, :normal}
      assert Worker.whereis(other.task_id) == nil
      assert %{state: :working, outcome: nil, completed_at: nil} = Ash.get!(Run, other.id)
    end

    # An adopter cut off between starting the Worker and the session open (§10.4.6 F12).
    test "a Worker whose adopter goes down before a session attached the run gives the adoption up" do
      row = row!()
      adopter = spawn(fn -> receive(do: (:go -> :ok)) end)
      meta = %{adopt: Map.put(adopt_info(row), :adopter, adopter)}
      {:ok, pid} = Worker.start(task_id: row.task_id, repo: "arbiter", meta: meta)
      ref = Process.monitor(pid)

      send(adopter, :go)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert Worker.whereis(row.task_id) == nil
      assert %{state: :working, outcome: nil, completed_at: nil} = Ash.get!(Run, row.id)
      assert rows_for(row.task_id) == [row.id]
    end

    test "a Worker started after its adopter was already gone gives the adoption up at once" do
      row = row!()
      adopter = spawn(fn -> :ok end)
      gone = Process.monitor(adopter)
      assert_receive {:DOWN, ^gone, :process, ^adopter, _}

      meta = %{adopt: Map.put(adopt_info(row), :adopter, adopter)}
      {:ok, pid} = Worker.start(task_id: row.task_id, repo: "arbiter", meta: meta)
      ref = Process.monitor(pid)

      # :normal, or :noproc if it was already gone
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      assert Worker.whereis(row.task_id) == nil
      assert %{state: :working, outcome: nil, completed_at: nil} = Ash.get!(Run, row.id)
    end

    test "once a session attached the run, its adopter going down changes nothing" do
      row = row!()
      adopter = spawn(fn -> receive(do: (:go -> :ok)) end)
      meta = %{adopt: Map.put(adopt_info(row), :adopter, adopter)}
      {:ok, pid} = Worker.start(task_id: row.task_id, repo: "arbiter", meta: meta)
      on_exit(fn -> if Process.alive?(pid), do: Worker.abandon_adoption(pid) end)
      _handle = open!(pid, row.node_id, row.id)

      gone = Process.monitor(adopter)
      send(adopter, :go)
      assert_receive {:DOWN, ^gone, :process, ^adopter, _}
      _ = :sys.get_state(pid)

      assert Worker.whereis(row.task_id) == pid
      assert %{run_id: run_id} = Worker.state(pid)
      assert run_id == row.id
    end

    test "a shutdown before its session opened leaves the row live for the next boot" do
      put_env!(:worker_node_stopping_override, true)
      sup = start_sup!()
      row = row!()

      _pid =
        start_under!(sup, task_id: row.task_id, repo: "arbiter", meta: %{adopt: adopt_info(row)})

      stop_sup!()
      assert %{state: :working, outcome: nil, completed_at: nil} = Ash.get!(Run, row.id)
    end
  end

  # §10.4.5: what a graceful stop records so the adopter starts exactly where it left off.
  describe "stdout_offset" do
    test "a Worker leaving its live remote run at a graceful stop records the stdout bytes it processed" do
      put_env!(:worker_node_stopping_override, true)
      sup = start_sup!()
      task_id = new_task_id()
      pid = start_under!(sup, task_id: task_id, repo: "arbiter")
      run_id = Worker.state(pid).run_id
      node_id = Ecto.UUID.generate()
      handle = open!(pid, node_id, run_id)
      # what Dispatch does once the session is up
      _ = Worker.advance(pid, :claude)

      # {:eol, l} is |l| + 1 bytes, {:noeol, c} is |c|: 4 + 3 + 1
      send(pid, {handle, {:data, {:eol, "abc"}}})
      send(pid, {handle, {:data, {:noeol, "xyz"}}})
      send(pid, {handle, {:data, {:eol, ""}}})
      _ = :sys.get_state(pid)

      stop_sup!()
      run = Ash.get!(Run, run_id)
      assert run.stdout_offset == 8
      # left to the node, not written off
      assert run.state == :working
      assert run.outcome == nil
    end

    test "an adopted Worker counts from where its stream started" do
      put_env!(:worker_node_stopping_override, true)
      sup = start_sup!()
      row = row!()

      pid =
        start_under!(sup,
          task_id: row.task_id,
          repo: "arbiter",
          meta: %{adopt: adopt_info(row, 90)}
        )

      handle = open!(pid, row.node_id, row.id, 100)

      send(pid, {handle, {:data, {:eol, "ab"}}})
      _ = :sys.get_state(pid)

      stop_sup!()
      assert %{stdout_offset: 103, state: :working} = Ash.get!(Run, row.id)
    end

    test "a Worker stopped while the application keeps running writes no offset" do
      task_id = new_task_id()
      {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter")
      run_id = Worker.state(pid).run_id
      handle = open!(pid, Ecto.UUID.generate(), run_id)
      send(pid, {handle, {:data, {:eol, "abc"}}})
      _ = :sys.get_state(pid)

      :ok = Worker.stop(pid, :normal)
      assert Ash.get!(Run, run_id).stdout_offset == nil
    end
  end

  # §10.4.10 (bd-8ikgoc): a run on a node holds no slot on the primary.
  test "a Worker whose remote session opens names the node in its registry entry" do
    task_id = new_task_id()
    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter")
    on_exit(fn -> if Process.alive?(pid), do: Worker.stop(pid, :normal) end)
    assert %{node_id: nil} = registry_entry(task_id)

    node_id = Ecto.UUID.generate()
    _handle = open!(pid, node_id, Worker.state(pid).run_id)
    assert %{node_id: ^node_id} = registry_entry(task_id)
  end
end
