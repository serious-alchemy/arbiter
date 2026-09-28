defmodule ArbiterWeb.WorkerDetailAsyncTest do
  @moduledoc """
  bd-c5m9b5: `/workers/:task_id` used to call into the worker for its snapshot
  and read the task, workspace, machine state, mailbox, latest run and usage
  synchronously in `mount/3`, on the dead render and the connected one alike.
  A busy worker held the whole page.

  Both now load via `start_async/3` on the connected mount: the worker
  snapshot in one task, the database reads in another. These tests pin the
  loading, loaded and inline error states of each, and the seam between the
  seeded output buffer and the live output topic: a line the worker streams
  while its snapshot is in flight is shown exactly once.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "wda-ws-#{System.unique_integer([:positive])}", prefix: "wda"})

    {:ok, task} = Ash.create(Issue, %{title: "wda-task", workspace_id: ws.id})
    {:ok, ws: ws, task: task}
  end

  # A stand-in worker registered under `task_id`: it answers the snapshot call
  # only when the test says so, and streams output from its own process, the
  # way a real worker does, so the ordering the page relies on is the real one.
  defp fake_worker(task_id, output_lines) do
    snapshot = template_snapshot(task_id, output_lines)
    test = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(Arbiter.Worker.Registry, task_id, nil)
        send(test, {:fake_registered, self()})
        fake_loop(test, task_id, snapshot)
      end)

    assert_receive {:fake_registered, ^pid}
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  # A real worker's snapshot, so the page renders the fake exactly as it would
  # a live one.
  defp template_snapshot(task_id, output_lines) do
    {:ok, pid} = Worker.start(task_id: "wda-tpl-#{System.unique_integer([:positive])}", repo: "r")
    snapshot = Worker.state(pid)
    :ok = Worker.stop(snapshot.task_id)

    snapshot
    |> Map.put(:task_id, task_id)
    |> Map.merge(%{state: :working, outcome: nil, waiting_on: nil})
    |> Map.put(:meta, Map.put(snapshot.meta, :output_lines, output_lines))
  end

  defp fake_loop(test, task_id, snapshot) do
    receive do
      {:"$gen_call", from, {:snapshot, {notify, ref}}} ->
        send(test, {:snapshot_requested, self()})

        receive do
          # `pre` is streamed before the worker takes its snapshot (so it is
          # in the snapshot too), `post` right after it answers.
          {:answer, pre, post} ->
            Enum.each(pre, &emit(task_id, &1))
            send(notify, {:worker_snapshot_cut, ref})
            snapshot = put_in(snapshot.meta.output_lines, snapshot.meta.output_lines ++ pre)
            GenServer.reply(from, snapshot)
            Enum.each(post, &emit(task_id, &1))
            fake_loop(test, task_id, snapshot)

          # The same, but with the page seeing it in the other order: the
          # snapshot lands before the lines (and marker) streamed ahead of it.
          {:answer_cut_late, pre, post} ->
            snapshot = put_in(snapshot.meta.output_lines, snapshot.meta.output_lines ++ pre)
            GenServer.reply(from, snapshot)

            receive do
              :deliver -> :ok
            end

            Enum.each(pre, &emit(task_id, &1))
            send(notify, {:worker_snapshot_cut, ref})
            Enum.each(post, &emit(task_id, &1))
            send(test, :delivered)
            fake_loop(test, task_id, snapshot)

          # Answers as a worker that has moved on: `run` is the new
          # `state` / `outcome` / `waiting_on` (bd-1uu19b).
          {:answer_run, run} ->
            GenServer.reply(from, Map.merge(snapshot, run))
            fake_loop(test, task_id, snapshot)

          :crash ->
            exit(:boom)
        end

      {:"$gen_call", from, :snapshot} ->
        GenServer.reply(from, snapshot)
        fake_loop(test, task_id, snapshot)
    end
  end

  defp emit(task_id, line) do
    Phoenix.PubSub.broadcast(
      Arbiter.PubSub,
      "worker:" <> task_id,
      {:worker_output, task_id, line}
    )
  end

  defp output_texts(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#worker-output span[title]")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  describe "the worker snapshot" do
    test "the dead render shows the loading state and never calls the worker", %{
      conn: conn,
      task: task
    } do
      _fake = fake_worker(task.id, ["seeded"])

      html = conn |> get(~p"/workers/#{task.id}") |> html_response(200)

      assert html =~ ~s(id="worker-snapshot-loading")
      assert html =~ ~s(id="worker-details-loading")
      refute html =~ "seeded"
      refute_received {:snapshot_requested, _}
    end

    test "renders a loading state, then the snapshot", %{conn: conn, task: task} do
      _fake = fake_worker(task.id, ["seeded"])

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      assert_receive {:snapshot_requested, fake}

      assert has_element?(view, "#worker-snapshot-loading")
      refute has_element?(view, "#worker-output")

      send(fake, {:answer, [], []})
      render_async(view)

      refute has_element?(view, "#worker-snapshot-loading")
      assert has_element?(view, "#worker-stop-btn")
      assert output_texts(view) == ["seeded"]
    end

    test "output streamed while the snapshot is in flight is neither lost nor duplicated", %{
      conn: conn,
      task: task
    } do
      _fake = fake_worker(task.id, ["seeded"])

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      assert_receive {:snapshot_requested, fake}

      # Lines the worker streams before it snapshots reach the page on the
      # output topic *and* inside the snapshot; lines after it only on the
      # topic, possibly ahead of the snapshot itself.
      send(fake, {:answer, ["before-1", "before-2"], ["after-1", "after-2"]})
      render_async(view)

      assert output_texts(view) == ["seeded", "before-1", "before-2", "after-1", "after-2"]

      emit(task.id, "later")

      assert output_texts(view) == [
               "seeded",
               "before-1",
               "before-2",
               "after-1",
               "after-2",
               "later"
             ]
    end

    test "a snapshot that lands before the worker's marker still shows each line once", %{
      conn: conn,
      task: task
    } do
      _fake = fake_worker(task.id, ["seeded"])

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      assert_receive {:snapshot_requested, fake}

      send(fake, {:answer_cut_late, ["before-1"], ["after-1"]})
      render_async(view)
      assert output_texts(view) == ["seeded", "before-1"]

      send(fake, :deliver)
      assert_receive :delivered
      assert output_texts(view) == ["seeded", "before-1", "after-1"]
    end

    @tag :capture_log
    test "a failed snapshot renders an inline error, and Retry recovers",
         %{conn: conn, task: task} do
      fake = fake_worker(task.id, ["seeded"])

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      assert_receive {:snapshot_requested, ^fake}

      emit(task.id, "streamed-while-loading")
      ref = Process.monitor(fake)
      send(fake, :crash)
      assert_receive {:DOWN, ^ref, :process, ^fake, :boom}
      render_async(view)

      assert has_element?(view, "#worker-snapshot-error")
      refute has_element?(view, "#worker-snapshot-loading")

      # The worker is gone now, so Retry lands on the ordinary empty state.
      view |> element("#worker-snapshot-retry") |> render_click()
      render_async(view)

      refute has_element?(view, "#worker-snapshot-error")
      assert render(view) =~ "No worker registered"
    end

    @tag :capture_log
    test "a lifecycle event after a failed snapshot loads the page back in", %{
      conn: conn,
      task: task
    } do
      fake = fake_worker(task.id, ["seeded"])

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      assert_receive {:snapshot_requested, ^fake}

      ref = Process.monitor(fake)
      send(fake, :crash)
      assert_receive {:DOWN, ^ref, :process, ^fake, :boom}
      render_async(view)
      assert has_element?(view, "#worker-snapshot-error")

      # A fresh worker comes up for the task and announces itself.
      _replacement = fake_worker(task.id, ["seeded", "resumed"])
      send(view.pid, {:worker_lifecycle, :started, %{task_id: task.id}})
      assert_receive {:snapshot_requested, replacement}
      send(replacement, {:answer, [], []})
      render_async(view)

      refute has_element?(view, "#worker-snapshot-error")
      assert has_element?(view, "#worker-stop-btn")
      assert output_texts(view) == ["seeded", "resumed"]
    end

    test "a lifecycle event mid-load supersedes the snapshot in flight", %{
      conn: conn,
      task: task
    } do
      _fake = fake_worker(task.id, ["seeded"])

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      assert_receive {:snapshot_requested, fake}

      # The worker fails while the page's first snapshot call is queued, and
      # broadcasts it: the page asks again. The first answer was taken before
      # the failure; whichever order the two land in, the newer one wins.
      send(view.pid, {:worker_lifecycle, :failed, %{task_id: task.id}})
      send(fake, {:answer_run, %{state: :working}})
      assert_receive {:snapshot_requested, ^fake}
      send(fake, {:answer_run, %{state: :finished, outcome: :failed}})
      render_async(view)

      refute has_element?(view, "#worker-stop-btn")
      assert has_element?(view, "#worker-toolbar-resume-btn")
      assert output_texts(view) == ["seeded"]
    end

    test "a lifecycle refresh keeps the streamed buffer and the page up", %{
      conn: conn,
      task: task
    } do
      _fake = fake_worker(task.id, ["seeded"])

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      assert_receive {:snapshot_requested, fake}
      send(fake, {:answer, [], []})
      render_async(view)

      emit(task.id, "streamed")
      send(view.pid, {:worker_lifecycle, :updated, %{task_id: task.id}})
      assert_receive {:snapshot_requested, ^fake}

      # Still on the page while the reload is in flight, not a loading panel.
      refute has_element?(view, "#worker-snapshot-loading")
      assert has_element?(view, "#worker-stop-btn")

      send(fake, {:answer_run, %{state: :finished, outcome: :failed}})
      render_async(view)

      assert has_element?(view, "#worker-toolbar-resume-btn")
      assert output_texts(view) == ["seeded", "streamed"]
    end
  end

  describe "the database reads" do
    setup do
      :meck.new(Ash, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(Ash) end)
      :ok
    end

    test "render a loading state, then the task and mailbox", %{conn: conn, task: task} do
      test = self()

      :meck.expect(Ash, :get, fn
        Issue, id ->
          send(test, {:loading_task, self()})

          receive do
            :release -> :ok
          after
            1_000 -> send(test, :unreleased)
          end

          :meck.passthrough([Issue, id])

        resource, id ->
          :meck.passthrough([resource, id])
      end)

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      assert_receive {:loading_task, loader}

      assert has_element?(view, "#worker-details-loading")
      refute has_element?(view, "#mailbox-empty")
      refute has_element?(view, "#worker-fallback-resume-btn")

      send(loader, :release)
      render_async(view)

      refute has_element?(view, "#worker-details-loading")
      assert has_element?(view, "#mailbox-empty")
      # No worker, but the task has landed, so it can be resumed.
      assert has_element?(view, "#worker-fallback-resume-btn")
      refute_received :unreleased
    end

    @tag :capture_log
    test "a failed read renders an inline error, and Retry recovers", %{conn: conn, task: task} do
      :meck.expect(Ash, :get, fn
        Issue, _id -> raise "database is locked"
        resource, id -> :meck.passthrough([resource, id])
      end)

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      render_async(view)

      assert has_element?(view, "#worker-details-error", "database is locked")
      refute has_element?(view, "#worker-details-loading")
      refute has_element?(view, "#worker-fallback-resume-btn")

      :meck.expect(Ash, :get, fn resource, id -> :meck.passthrough([resource, id]) end)
      view |> element("#worker-details-retry") |> render_click()
      render_async(view)

      refute has_element?(view, "#worker-details-error")
      assert has_element?(view, "#worker-fallback-resume-btn")
    end

    @tag :capture_log
    test "a lifecycle event after a failed read loads the details back in", %{
      conn: conn,
      ws: ws,
      task: task
    } do
      :meck.expect(Ash, :get, fn
        Issue, _id -> raise "database is locked"
        resource, id -> :meck.passthrough([resource, id])
      end)

      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      render_async(view)
      assert has_element?(view, "#worker-details-error")

      :meck.expect(Ash, :get, fn resource, id -> :meck.passthrough([resource, id]) end)
      send(view.pid, {:worker_lifecycle, :stopped, %{task_id: task.id}})
      render_async(view)

      refute has_element?(view, "#worker-details-error")
      assert has_element?(view, "#mailbox-empty")

      # And the mailbox topic is live again.
      {:ok, _msg} =
        Arbiter.Messages.Message.send_mail(%{
          kind: :direction,
          from_ref: Arbiter.Messages.Message.coordinator_ref(),
          to_ref: task.id,
          workspace_id: ws.id,
          body: "arrived-after-reload"
        })

      assert render(view) =~ "arrived-after-reload"
    end

    test "the mailbox subscription follows the loaded task", %{conn: conn, ws: ws, task: task} do
      {:ok, view, _html} = live(conn, ~p"/workers/#{task.id}")
      render_async(view)
      assert has_element?(view, "#mailbox-empty")

      {:ok, _msg} =
        Arbiter.Messages.Message.send_mail(%{
          kind: :direction,
          from_ref: Arbiter.Messages.Message.coordinator_ref(),
          to_ref: task.id,
          workspace_id: ws.id,
          body: "arrived-after-load"
        })

      assert render(view) =~ "arrived-after-load"
    end
  end
end
