defmodule Arbiter.Worker.RepoCapTest do
  @moduledoc """
  DC9 (bd-7oy77e; design `docs/design/provider-dynamic-concurrency.md` §5.2):
  the repo cap `worker.repos.<repo>.max_concurrent`. The pure counting core
  first, then the registry-backed count and the admission against real
  processes and tickets.
  """
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Repo
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.RepoCap
  alias Arbiter.Worker.Registry, as: WorkerRegistry

  defp entry(key, repo, extra \\ %{}) do
    Map.merge(
      %{registry_key: key, workspace_id: "ws", repo: repo, released: false},
      extra
    )
  end

  defp active(repo \\ nil), do: %{state: :active, repo: repo}

  defp counts(entries, tickets),
    do: entries |> RepoCap.holders(tickets) |> Map.new(fn {k, v} -> {k, length(v)} end)

  describe "limits/1 and limit/2" do
    test "reads the positive integer caps per repo; an unset or invalid one is no cap" do
      config = %{
        "worker" => %{
          "repos" => %{
            "vstim" => %{"max_concurrent" => 2},
            "other" => %{"seed_paths" => []},
            "bad" => %{"max_concurrent" => 0},
            "str" => %{"max_concurrent" => "3"}
          }
        }
      }

      assert RepoCap.limits(config) == %{"vstim" => 2}
      assert RepoCap.limit(config, "vstim") == 2
      assert RepoCap.limit(config, "other") == nil
      assert RepoCap.limit(config, nil) == nil
      assert RepoCap.limits(%{}) == %{}
      assert RepoCap.limits(nil) == %{}
    end

    test "takes a workspace as well as its config" do
      ws = %Workspace{config: %{"worker" => %{"repos" => %{"vstim" => %{"max_concurrent" => 4}}}}}
      assert RepoCap.limit(ws, "vstim") == 4
    end
  end

  describe "implementer_key?/1" do
    test "the implementer, its fix pass, conflict pass and a ReviewGate fix round count" do
      for key <- ["t1", "t1:fixpass", "t1:conflict", "t1#review#impl1", "t1#review#impl1#t2"] do
        assert RepoCap.implementer_key?(key), key
      end
    end

    test "reviewers, their rounds and their retries do not" do
      for key <- ["t1#review", "t1#review#r1", "t1#review#v2", "t1#review#t2"] do
        refute RepoCap.implementer_key?(key), key
      end
    end
  end

  describe "holders/2 (pure)" do
    test "an In-progress implementer holds one run in its repo" do
      assert counts([entry("t1", "vstim")], %{"t1" => active()}) == %{{"ws", "vstim"} => 1}
    end

    test "a fix pass, a conflict pass and a fix round each hold a run" do
      entries = [
        entry("t1", "vstim"),
        entry("t1:fixpass", "vstim"),
        entry("t2:conflict", "vstim"),
        entry("t3#review#impl1", "vstim")
      ]

      tickets = %{"t1" => active(), "t2" => %{state: :merging, repo: nil}, "t3" => active()}
      assert counts(entries, tickets) == %{{"ws", "vstim"} => 4}
    end

    test "reviewers are excluded" do
      entries = [entry("t1#review", "vstim"), entry("t1#review#r2", "vstim")]
      assert counts(entries, %{"t1" => active()}) == %{}
    end

    test "a Merging ticket's parked primary holds nothing: its pipeline is not counted (O3)" do
      assert counts([entry("t1", "vstim")], %{"t1" => %{state: :merging, repo: nil}}) == %{}
    end

    test "a primary released to wait for CI is not writing, so it holds nothing" do
      assert counts([entry("t1", "vstim", %{released: true})], %{"t1" => active()}) == %{}
    end

    test "a primary whose ticket cannot be read fails closed and holds a run" do
      assert counts([entry("t1", "vstim")], %{}) == %{{"ws", "vstim"} => 1}
    end

    test "a run that stamped no repo takes its ticket's" do
      for stamped <- [nil, "", "unknown"] do
        assert counts([entry("t1", stamped)], %{"t1" => active("vstim")}) ==
                 %{{"ws", "vstim"} => 1}
      end

      assert counts([entry("t1", nil)], %{"t1" => active()}) == %{}
    end

    test "a reservation holds a run until its worker's entry exists" do
      reservation = entry("t1", "vstim", %{reservation: true})
      assert counts([reservation], %{}) == %{{"ws", "vstim"} => 1}

      assert counts([reservation, entry("t1", "vstim")], %{"t1" => active()}) ==
               %{{"ws", "vstim"} => 1}
    end

    test "repos and workspaces are counted apart" do
      entries = [
        entry("t1", "vstim"),
        entry("t2", "arbiter"),
        entry("t3", "vstim", %{workspace_id: "other"})
      ]

      tickets = %{"t1" => active(), "t2" => active(), "t3" => active()}

      assert counts(entries, tickets) ==
               %{{"ws", "vstim"} => 1, {"ws", "arbiter"} => 1, {"other", "vstim"} => 1}
    end
  end

  describe "live count and admission" do
    defp ticket!(ws, state, repo \\ nil) do
      id = "rc-#{System.unique_integer([:positive])}"
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      Repo.query!(
        """
        INSERT INTO issues (id, workspace_id, title, issue_type, priority, tracker_type,
                            state, repo, created_at, updated_at)
        VALUES (?1, ?2, ?1, 'feature', 2, 'none', ?3, ?5, ?4, ?4)
        """,
        [id, ws.id, to_string(state), now, repo]
      )

      Ash.get!(Issue, id)
    end

    defp fake_worker(key, ws, repo, opts \\ []) do
      test = self()

      pid =
        spawn(fn ->
          {:ok, _} = Registry.register(WorkerRegistry, key, nil)
          :ok = WorkerRegistry.put_dispatch(key, ws.id, "claude", [repo: repo] ++ opts)
          send(test, {:registered, self()})
          Process.sleep(:infinity)
        end)

      assert_receive {:registered, ^pid}
      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end

    defp reserve_in_other_process(task, repo) do
      test = self()

      pid =
        spawn(fn ->
          send(test, {:admit, RepoCap.admit(task, repo, limit: 2)})

          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      assert_receive {:admit, result}
      result
    end

    setup do
      ws =
        Ash.create!(Workspace, %{
          name: "rc-#{System.unique_integer([:positive])}",
          config: %{"worker" => %{"repos" => %{"vstim" => %{"max_concurrent" => 2}}}}
        })

      %{ws: ws}
    end

    test "put_dispatch stamps the repo, and it survives a rewrite", %{ws: ws} do
      key = "rc-stamp-#{System.unique_integer([:positive])}"
      test = self()

      pid =
        spawn(fn ->
          {:ok, _} = Registry.register(WorkerRegistry, key, nil)
          :ok = WorkerRegistry.put_dispatch(key, ws.id, "claude", repo: "vstim")
          :ok = WorkerRegistry.put_dispatch(key, ws.id, "claude", released: true)
          send(test, :stamped)
          Process.sleep(:infinity)
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      assert_receive :stamped

      assert %{repo: "vstim", released: true} =
               Enum.find(WorkerRegistry.live_dispatches(), &(&1.registry_key == key))
    end

    test "count/2 reads the live registry: implementers in, reviewers and Merging parks out",
         %{ws: ws} do
      a = ticket!(ws, :active)
      b = ticket!(ws, :merging)
      c = ticket!(ws, :active)
      fake_worker(a.id, ws, "vstim")
      fake_worker(b.id, ws, "vstim")
      fake_worker(b.id <> ":fixpass", ws, "vstim")
      fake_worker(c.id <> "#review", ws, "vstim")

      assert RepoCap.count(ws.id, "vstim") == 2
      assert RepoCap.counts()[{ws.id, "vstim"}] == 2
      assert RepoCap.count(ws.id, "arbiter") == 0
    end

    test "a killed worker frees its run with no decrement", %{ws: ws} do
      t = ticket!(ws, :active)
      pid = fake_worker(t.id, ws, "vstim")
      assert RepoCap.count(ws.id, "vstim") == 1

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      assert RepoCap.count(ws.id, "vstim") == 0
    end

    test "admit/3 admits up to the cap, then refuses with who holds the runs", %{ws: ws} do
      [a, b, c] = for _ <- 1..3, do: ticket!(ws, :ready)

      assert {:ok, :admitted} = reserve_in_other_process(a, "vstim")
      assert {:ok, :admitted} = reserve_in_other_process(b, "vstim")
      assert RepoCap.count(ws.id, "vstim") == 2

      assert {:error, {:repo_at_capacity, info}} = reserve_in_other_process(c, "vstim")
      assert %{task_id: task_id, repo: "vstim", cap: 2, holders: holders} = info
      assert task_id == c.id
      assert Enum.sort(holders) == Enum.sort([a.id, b.id])
      assert RepoCap.refusal_message(info) =~ "repo vstim"
      assert RepoCap.refusal_message(info) =~ "2 of 2"
    end

    test "a reservation counts until its worker registers, and is released with its owner",
         %{ws: ws} do
      # Dispatch moves the ticket to In progress before its worker starts.
      a = ticket!(ws, :active)
      assert {:ok, :admitted} = reserve_in_other_process(a, "vstim")
      assert RepoCap.count(ws.id, "vstim") == 1

      # The worker's own entry takes over the same key: still one run.
      fake_worker(a.id, ws, "vstim")
      assert RepoCap.count(ws.id, "vstim") == 1
    end

    test "release/1 drops the calling process's reservation", %{ws: ws} do
      a = ticket!(ws, :ready)
      assert {:ok, :admitted} = RepoCap.admit(a, "vstim", limit: 2)
      assert RepoCap.count(ws.id, "vstim") == 1

      assert :ok = RepoCap.release(a.id)
      assert RepoCap.count(ws.id, "vstim") == 0
    end

    test "force goes over the cap and is recorded", %{ws: ws} do
      [a, b, c] = for _ <- 1..3, do: ticket!(ws, :ready)
      assert {:ok, :admitted} = reserve_in_other_process(a, "vstim")
      assert {:ok, :admitted} = reserve_in_other_process(b, "vstim")

      assert {:ok, :forced} = RepoCap.admit(c, "vstim", limit: 2, force: true, actor: "ryan")
      assert RepoCap.count(ws.id, "vstim") == 3

      assert [event] =
               Arbiter.Events.Record
               |> Ash.Query.filter(workspace_id == ^ws.id and topic == "repo_cap_override")
               |> Ash.read!()

      assert %{"task_id" => task_id, "repo" => "vstim", "cap" => 2, "actor" => "ryan"} =
               event.payload

      assert task_id == c.id
      assert "repo_cap_override" in Arbiter.Events.valid_topics()
    end

    test "no cap, or no repo, admits nothing to count", %{ws: ws} do
      a = ticket!(ws, :ready)
      assert {:ok, :unlimited} = RepoCap.admit(a, "vstim", limit: nil)
      assert {:ok, :unlimited} = RepoCap.admit(a, nil, limit: 2)
      assert RepoCap.count(ws.id, "vstim") == 0
    end
  end
end
