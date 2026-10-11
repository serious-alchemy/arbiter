defmodule Arbiter.Worker.DispatchRepoCapTest do
  @moduledoc """
  `ensure_repo_capacity/2` (DC9, bd-7oy77e; design
  `docs/design/provider-dynamic-concurrency.md` §5.2): a fresh dispatch into a
  repo at its `worker.repos.<repo>.max_concurrent` is refused, a follow-up never
  is, and until `scheduler_admission: enforce` (DC8) it decides nothing (I1, I2).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Worker.RepoCap

  require Ash.Query

  @repo ResumeSlotFixture.repo()

  setup do
    ResumeSlotFixture.setup_repo!()
    # The machine cap is not under test.
    ResumeSlotFixture.put_local_cap(10)

    ws =
      Ash.create!(Workspace, %{
        name: "repo-cap-#{System.unique_integer([:positive])}",
        prefix: "rc#{System.unique_integer([:positive])}",
        config: %{"worker" => %{"repos" => %{@repo => %{"max_concurrent" => 1}}}}
      })

    %{ws: ws}
  end

  defp backlog!(ws, title) do
    {:ok, issue} = Ash.create(Issue, %{title: title, workspace_id: ws.id})
    issue
  end

  defp ready!(ws, title) do
    {:ok, created} =
      Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- repo cap fixture"})

    {:ok, issue} = Ash.update(created, %{}, action: :promote_to_ready)
    issue
  end

  defp dispatch(issue, opts \\ []) do
    defaults = [
      dispatched_by: "autopilot",
      repo: @repo,
      start_driver: false,
      scheduler_admission: :enforce
    ]

    Dispatch.dispatch(issue.id, Keyword.merge(defaults, opts))
  end

  defp events(ws, topic) do
    Arbiter.Events.Record
    |> Ash.Query.filter(workspace_id == ^ws.id and topic == ^topic)
    |> Ash.read!()
  end

  describe "under enforce" do
    test "a fresh dispatch is admitted up to the cap, then refused with who holds the run",
         %{ws: ws} do
      first = ready!(ws, "first")
      second = ready!(ws, "second")

      assert {:ok, %{worker_pid: pid}} = dispatch(first)
      assert is_pid(pid)
      assert RepoCap.count(ws.id, @repo) == 1

      assert {:error, {:repo_at_capacity, info}} = dispatch(second)
      assert %{task_id: task_id, repo: @repo, cap: 1, holders: [holder]} = info
      assert task_id == second.id
      assert holder == first.id

      # Nothing started, and the card is still Ready.
      assert Worker.whereis(second.id) == nil
      assert Ash.get!(Issue, second.id).state == :queued
    end

    test "the refusal leaves no reservation behind", %{ws: ws} do
      first = ready!(ws, "first")
      second = ready!(ws, "second")
      {:ok, %{worker_pid: pid}} = dispatch(first)
      assert {:error, {:repo_at_capacity, _}} = dispatch(second)

      ref = Process.monitor(pid)
      :ok = Worker.stop(first.id, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

      assert RepoCap.count(ws.id, @repo) == 0
      assert {:ok, %{worker_pid: _}} = dispatch(second)
    end

    test "a workspace with no cap on the repo is untouched" do
      ws =
        Ash.create!(Workspace, %{
          name: "repo-cap-open-2953",
          prefix: "ro3017"
        })

      assert {:ok, _} = dispatch(ready!(ws, "a"))
      assert {:ok, _} = dispatch(ready!(ws, "b"))
      assert RepoCap.pending() == []
    end

    test "force_slot goes over the cap and the override is recorded", %{ws: ws} do
      {:ok, _} = dispatch(ready!(ws, "first"))
      over = ready!(ws, "over")

      assert {:ok, %{worker_pid: pid}} =
               dispatch(over, force_slot: true, slot_override_actor: "api")

      assert is_pid(pid)
      assert [event] = events(ws, "repo_cap_override")
      assert event.payload["task_id"] == over.id
      assert event.payload["cap"] == 1
      assert event.payload["actor"] == "api"
    end

    test "a follow-up of an In-progress ticket is never held by the cap", %{ws: ws} do
      first = backlog!(ws, "interrupted")
      # Started under `legacy`, where the cap decides nothing.
      {:ok, %{worker_pid: pid}} =
        Dispatch.dispatch(first.id, force: true, repo: @repo, start_driver: false)

      ref = Process.monitor(pid)
      :ok = Worker.stop(first.id, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000

      # The repo is full again with another ticket's run...
      {:ok, _} = dispatch(ready!(ws, "other"))
      assert RepoCap.count(ws.id, @repo) == 1

      # ...and the interrupted ticket's resume still starts (finishing is not held).
      assert {:ok, %{worker_pid: resumed}} =
               Dispatch.resume(first.id,
                 start_driver: false,
                 resume_origin: :human,
                 scheduler_admission: :enforce
               )

      assert is_pid(resumed)
      assert RepoCap.count(ws.id, @repo) == 2
    end
  end

  describe "before DC8 (legacy and shadow)" do
    for mode <- [:legacy, :shadow] do
      test "#{mode}: the cap decides nothing and no count is read", %{ws: ws} do
        {:ok, _} = dispatch(ready!(ws, "first"), scheduler_admission: unquote(mode))
        {:ok, _} = dispatch(ready!(ws, "second"), scheduler_admission: unquote(mode))

        assert RepoCap.count(ws.id, @repo) == 2
        assert RepoCap.pending() == []
      end
    end

    test "the mode defaults to the installation's scheduler_admission setting (legacy)", %{ws: ws} do
      {:ok, _} = dispatch(ready!(ws, "first"), scheduler_admission: nil)
      assert {:ok, _} = dispatch(ready!(ws, "second"), scheduler_admission: nil)
    end
  end
end
