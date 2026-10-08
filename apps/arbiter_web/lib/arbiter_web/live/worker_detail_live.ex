defmodule ArbiterWeb.WorkerDetailLive do
  @moduledoc """
  Per-worker detail view at `/workers/:task_id`. The richest single
  view of a worker: snapshot, captured Claude stdout (a sticky-bottom
  LogStream), the paired workflow Machine's step progress, the
  task's workspace context, and a Stop/Resume action.

  Subscribes to:
    * `"workers"`          — lifecycle events (started / stopped).
    * `"worker:<task-id>"`  — per-line stdout events.
    * `"messages:<ws_id>"`   — `{:new_message, _}` so the mailbox panel
                               updates live when direction/flags arrive.
    * `"tasks"` and `Arbiter.Tasks.PullRequest.topic/0` — the ticket's own
      changes and every poll its Watchdog records, for the merge-request
      panel. Since bd-741sid that panel is the ticket's: no worker stays
      resident on an open PR.
  """

  use ArbiterWeb, :live_view

  import ArbiterWeb.StatusHelpers

  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Feedback
  alias ArbiterWeb.CoreComponents.Navigation
  alias ArbiterWeb.QuotaHelpers

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.PullRequest
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Workers.Run
  alias Arbiter.Workers.RunNode
  alias Arbiter.Workflows.MachineState
  require Ash.Query
  require Logger

  @workers_topic "workers"
  # Live tail buffer cap. Keeps memory bounded on chatty children — older
  # lines roll off the head of the assign as new ones arrive. The worker
  # itself caps at a higher number (Arbiter.Worker.ClaudeSession.line_cap/0)
  # so a full reload after a refresh still shows reasonable history.
  @output_cap 200

  # bd-c5m9b5: the worker snapshot and the database reads (task, workspace,
  # machine state, mailbox, latest run, usage) used to run synchronously here,
  # on the dead render and the connected one alike — a GenServer hop into a
  # possibly busy worker held the whole page. The dead render now reads
  # nothing and draws the loading states; the connected mount starts two
  # `start_async/3` tasks, one per source, so a slow worker never holds the
  # mailbox and a slow database never holds the log.
  #
  # The output topic is subscribed *before* the snapshot is asked for, so no
  # line can fall between the two; `@output_seam` then sorts every line that
  # lands while the snapshot is in flight into "already in the snapshot" or
  # "after it" — see `load_snapshot/1`.
  #
  # Every later refresh (a lifecycle event, a finished Resume or watchdog
  # restart) goes through the same two tasks — see `refresh_all/1`.
  @impl true
  def mount(%{"task_id" => task_id}, _session, socket) do
    socket =
      socket
      |> assign(:task_id, task_id)
      |> assign(:now, DateTime.utc_now())
      |> assign(:flash_message, nil)
      |> assign(:compose_body, "")
      |> assign(:worker_label, "worker")
      |> assign(:issue_label, "ticket")
      |> assign(:repo_label, "repo")
      |> assign(:workspace_label, "workspace")
      |> assign(:pr_label, "pull request")
      |> assign(:retry_modal, false)
      |> assign(:retry_error, nil)
      |> assign(:retry_over_cap, false)
      |> assign(:retrying, false)
      |> assign(:restarting_watchdog, false)
      |> assign(:stop_notice, false)
      |> assign(:stopped_flow_step, nil)
      |> assign(:snapshot, nil)
      |> assign(:snapshot_state, :loading)
      |> assign(:snapshot_ref, nil)
      |> assign(:output_lines, [])
      |> assign(:output_seam, nil)
      |> assign(:details_state, :loading)
      |> assign(:mailbox_topic, nil)
      |> assign(:details_reload, nil)
      |> assign(empty_details())

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Arbiter.PubSub, @workers_topic)
        Phoenix.PubSub.subscribe(Arbiter.PubSub, output_topic(task_id))
        Phoenix.PubSub.subscribe(Arbiter.PubSub, "tasks")
        Phoenix.PubSub.subscribe(Arbiter.PubSub, PullRequest.topic())
        # Drives the live elapsed-time counter in the header. Only reassigns
        # :now — no DB reads or GenServer hops in the tick handler.
        :timer.send_interval(1000, self(), :tick)

        socket
        |> load_snapshot()
        |> reload_details()
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  # A worker's own `terminate/2` broadcasts `:stopped` on the shared "workers"
  # topic, and `Worker.stop/3` blocks until that broadcast has already landed
  # in our own mailbox. Left unguarded, the very next receive loop after our
  # `"stop"` handler would refresh straight over the synthetic stopped
  # snapshot/flow position we just built (`Worker.whereis/1` is already `nil`
  # by then) — flipping the toast/chip/flow back off before the operator ever
  # sees them. Once we're showing the stop notice, drop this task's own
  # `:stopped` echo; any other lifecycle event still refreshes normally.
  def handle_info(
        {:worker_lifecycle, :stopped, %{task_id: task_id}},
        %{assigns: %{stop_notice: true, task_id: task_id}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_info(
        {:worker_lifecycle, _event, %{task_id: task_id}},
        %{assigns: %{task_id: task_id}} = socket
      ) do
    {:noreply, refresh_all(socket)}
  end

  # A lifecycle event for some other worker on the shared "workers" topic —
  # not ours, so it must not touch our snapshot/toast/flow state.
  def handle_info({:worker_lifecycle, _event, _snap}, socket), do: {:noreply, socket}

  # The ticket changed, or its Watchdog recorded a poll: the merge-request
  # panel reads both off the row, which the details load re-reads.
  def handle_info({:task_lifecycle, _event, %{id: task_id}}, %{assigns: %{task_id: task_id}} = s),
    do: {:noreply, reload_details(s)}

  def handle_info({:task_lifecycle, _event, _task}, socket), do: {:noreply, socket}

  def handle_info({:pull_request, _event, task_id}, %{assigns: %{task_id: task_id}} = socket),
    do: {:noreply, reload_details(socket)}

  def handle_info({:pull_request, _event, _task_id}, socket), do: {:noreply, socket}

  def handle_info({:worker_output, _task_id, line}, socket) do
    {:noreply, receive_output_line(socket, line)}
  end

  # The worker's marker for the snapshot in flight: every line before it is
  # in that snapshot, every line after it is not (`Worker.state/3`).
  def handle_info(
        {:worker_snapshot_cut, ref},
        %{assigns: %{output_seam: %{ref: ref} = seam}} = socket
      ) do
    {:noreply, assign(socket, :output_seam, %{seam | cut?: true})}
  end

  # The snapshot landed first; from here on, lines are live again.
  def handle_info(
        {:worker_snapshot_cut, ref},
        %{assigns: %{output_seam: {:awaiting_cut, ref}}} = socket
      ) do
    {:noreply, assign(socket, :output_seam, nil)}
  end

  def handle_info({:new_message, _message}, socket) do
    {:noreply, refresh_mailbox(socket)}
  end

  def handle_info({:message_read, _message}, socket) do
    {:noreply, refresh_mailbox(socket)}
  end

  def handle_info({:mailbox_cleared, _workspace_id}, socket) do
    {:noreply, refresh_mailbox(socket)}
  end

  # Lightweight 1s tick: only advances the clock so the header's elapsed-time
  # counter stays live. No data reads here.
  def handle_info(:tick, socket) do
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  # Stays on the page rather than navigating away: the operator needs to see
  # the flipped Resume action, the reddened flow node, and the toast
  # confirming the worktree survives the stop. The pre-stop flow position is
  # captured before the GenServer terminates, so the flow can keep pointing
  # at the step the worker actually reached rather than a generic fallback.
  def handle_event("stop", _params, socket) do
    flow_step = current_flow_step(socket.assigns[:snapshot])

    case Worker.operator_stop(socket.assigns.task_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:stop_notice, true)
         |> assign(:stopped_flow_step, flow_step)
         |> supersede_snapshot_load()
         |> assign(:snapshot, stopped_snapshot(socket.assigns[:snapshot]))}

      {:error, :not_found} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Worker not registered (already gone?)."
         )}
    end
  end

  # ---- retry / resume ----
  #
  # The dashboard equivalent of `arb worker resume`: re-attach a *fresh* agent
  # to the task's preserved worktree, briefed with a git-derived summary of
  # what the stopped run already did. Like dispatch, it spends API credits, so
  # the modal is the confirmation step — the button only opens it.

  def handle_event("open_retry", _params, socket) do
    {:noreply, assign(socket, retry_modal: true, retry_error: nil, retry_over_cap: false)}
  end

  def handle_event("cancel_retry", _params, socket) do
    {:noreply, assign(socket, retry_modal: false, retry_error: nil, retry_over_cap: false)}
  end

  # A second click while one is in flight would spend credits twice.
  def handle_event("retry", _params, %{assigns: %{retrying: true}} = socket) do
    {:noreply, socket}
  end

  # `Dispatch.resume/2` runs the same expensive path dispatch does — provider
  # auth preflight (a CLI shell-out), quota gating, and an agent spawn. Running
  # it inline would block the LiveView process for the whole of it, stalling
  # queued `:worker_lifecycle` / `:worker_output` messages and risking the
  # client giving up before the result lands. Run it async and hold the modal
  # in a pending state instead.
  #
  # bd-92mx1m: a human resume. A task that released its slot re-acquires one;
  # at a full cap `Dispatch.resume/2` refuses (never defers), the modal says
  # why, and only then offers "retry_force" — the explicit, recorded override.
  def handle_event("retry", _params, socket), do: start_retry(socket, false)

  def handle_event("retry_force", _params, %{assigns: %{retrying: true}} = socket),
    do: {:noreply, socket}

  def handle_event("retry_force", _params, socket), do: start_retry(socket, true)

  # Re-arm one more auto-resolve attempt on a task's merge Watchdog once it's
  # exhausted its bounded retries on a :ci_failed block and parked (bd-bspakl).
  # Unlike "retry"/Resume above, this is a plain GenServer call into the
  # already-running Watchdog — no auth preflight, no agent spawn — so it runs
  # inline rather than via start_async.
  def handle_event("retry_auto_resolve", _params, socket) do
    task_id = socket.assigns.task_id

    case Watchdog.retry_auto_resolve(task_id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Re-armed auto-resolve for #{task_id}; a fresh fix-pass or conflict pass will start " <>
             "on the next watchdog poll."
         )
         |> refresh_all()}

      {:error, :not_found} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "No merge watchdog is currently running for #{task_id}."
         )}

      {:error, :not_parked_on_ci_failed} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "#{task_id} isn't parked on an exhausted CI-failed block or conflict yet — " <>
             "nothing to re-arm."
         )}

      {:error, :busy} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "#{task_id}'s watchdog is busy polling — try again in a moment."
         )}
    end
  end

  # Mint a fresh Watchdog for a ticket whose Watchdog died outright
  # (bd-8jixav), from the ticket's row (bd-741sid). Unlike "retry_auto_resolve"
  # above, this is not a cheap message to a live process: the new Watchdog
  # prepares its merger adapter, which for a hosted forge rewrites config and
  # can shell out. Run it async so a slow forge can't stall the LiveView (and
  # with it the `:worker_lifecycle` stream).
  #
  # An operator's own restart, so a ticket pulled out of the merge queue goes
  # back in it (`clear_pull: true`).
  def handle_event("restart_watchdog", _params, %{assigns: %{restarting_watchdog: true}} = socket) do
    {:noreply, socket}
  end

  def handle_event("restart_watchdog", _params, socket) do
    task_id = socket.assigns.task_id

    {:noreply,
     socket
     |> assign(:restarting_watchdog, true)
     |> start_async(:restart_watchdog, fn -> Watchdog.restart(task_id, clear_pull: true) end)}
  end

  def handle_event("compose_change", %{"body" => body}, socket) do
    {:noreply, assign(socket, :compose_body, body)}
  end

  def handle_event("send_direction", %{"body" => body}, socket) do
    task_id = socket.assigns.task_id

    case {String.trim(body || ""), workspace_id(socket)} do
      {"", _} ->
        {:noreply, put_flash(socket, :error, "Direction body can't be empty.")}

      {_text, nil} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "No workspace known for this ticket; can't address a direction."
         )}

      {text, ws_id} ->
        case Message.send_mail(%{
               kind: :direction,
               from_ref: Message.coordinator_ref(),
               to_ref: task_id,
               workspace_id: ws_id,
               body: text
             }) do
          {:ok, _msg} ->
            {:noreply,
             socket
             |> assign(:compose_body, "")
             |> put_flash(:info, "Direction sent to #{task_id}.")
             |> refresh_mailbox()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to send direction.")}
        end
    end
  end

  def handle_event("mark_read", %{"id" => id}, socket) do
    _ = Message.mark_read(id)
    {:noreply, refresh_mailbox(socket)}
  end

  def handle_event("retry_snapshot", _params, socket) do
    {:noreply, load_snapshot(socket)}
  end

  def handle_event("retry_details", _params, socket) do
    {:noreply, load_details(socket)}
  end

  # ---- async results ----

  @impl true
  # A worker back at a live run state (resumed, or restarted elsewhere)
  # retires the stop toast and the reddened flow node.
  def handle_async(:snapshot, {:ok, {ref, snapshot}}, %{assigns: %{snapshot_ref: ref}} = socket) do
    socket =
      socket
      |> assign(snapshot: snapshot, snapshot_state: :loaded, snapshot_ref: nil)
      |> land_output(snapshot)

    socket =
      case snapshot do
        %{state: _} ->
          if active_run?(snapshot),
            do: assign(socket, stop_notice: false, stopped_flow_step: nil),
            else: socket

        _ ->
          socket
      end

    {:noreply, socket}
  end

  # Taken before the operator's Stop landed (`supersede_snapshot_load/1`), so
  # it would put the stopped worker back on the page.
  def handle_async(:snapshot, {:ok, _stale}, socket), do: {:noreply, socket}

  def handle_async(:snapshot, {:exit, _reason}, %{assigns: %{snapshot_ref: nil}} = socket),
    do: {:noreply, socket}

  # The worker is there but its snapshot call crashed or timed out. Nothing
  # to seed from, so every line streamed meanwhile is kept as-is.
  def handle_async(:snapshot, {:exit, reason}, socket) do
    Logger.error("WorkerDetailLive: loading the worker snapshot failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(snapshot: nil, snapshot_state: {:error, describe_exit(reason)}, snapshot_ref: nil)
     |> land_output(nil)}
  end

  def handle_async(:details, {:ok, details}, socket) do
    {:noreply,
     socket
     |> assign(details)
     |> assign(:details_state, :loaded)
     |> subscribe_mailbox()
     |> settle_details_reload()}
  end

  def handle_async(:details, {:exit, reason}, socket) do
    Logger.error("WorkerDetailLive: loading the task details failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:details_state, {:error, describe_exit(reason)})
     |> settle_details_reload()}
  end

  def handle_async(:retry, {:ok, {:ok, _result}}, socket) do
    {:noreply,
     socket
     |> assign(
       retrying: false,
       retry_modal: false,
       retry_error: nil,
       stop_notice: false,
       stopped_flow_step: nil
     )
     |> put_flash(
       :info,
       "Resumed #{socket.assigns.task_id} with a fresh #{socket.assigns.worker_label}."
     )
     |> refresh_all()}
  end

  def handle_async(:retry, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:retrying, false)
     |> assign(:retry_over_cap, match?({:slot_cap_full, _}, reason))
     |> assign(:retry_error, "Resume failed: #{resume_failure(reason)}")
     |> refresh_all()}
  end

  def handle_async(:restart_watchdog, {:ok, result}, socket) do
    task_id = socket.assigns.task_id

    {kind, message} =
      case result do
        :ok ->
          {:info,
           "Restarted the merge watchdog for #{task_id}; it is polling the open " <>
             "#{socket.assigns.pr_label} again."}

        {:error, reason} ->
          {_kind, message} = Watchdog.restart_refusal(task_id, reason)
          {:error, message}
      end

    {:noreply,
     socket
     |> assign(:restarting_watchdog, false)
     |> put_flash(kind, message)
     |> refresh_all()}
  end

  def handle_async(:restart_watchdog, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:restarting_watchdog, false)
     |> put_flash(:error, "Watchdog restart crashed: #{inspect(reason)}")
     |> refresh_all()}
  end

  def handle_async(:retry, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:retrying, false)
     |> assign(:retry_error, "Resume crashed: #{inspect(reason)}")
     |> refresh_all()}
  end

  # ---- data ----

  # Asks the worker for its snapshot off the LiveView process. The worker
  # sends `{:worker_snapshot_cut, ref}` from its own process just before it
  # answers, so it is ordered with that worker's own `{:worker_output, _, _}`
  # broadcasts — which is what makes the seam exact. Until the snapshot lands,
  # a streamed line goes to `pre` (before the marker: already in the
  # snapshot) or `post` (after it: not); see `land_output/2`.
  #
  # Only a buffer that has not been seeded yet needs the seam. Once a
  # snapshot has landed, every line since has streamed straight in, so a
  # reload keeps the page (and its buffer, which may hold an earlier run's
  # lines) up while it asks again. Starting `:snapshot` again supersedes the
  # load in flight, so the newest request's answer is the one that lands.
  defp load_snapshot(socket) do
    task_id = socket.assigns.task_id
    view = self()
    ref = make_ref()

    socket =
      case socket.assigns do
        %{snapshot_state: :loaded} ->
          socket

        # Everything it caught was streamed before this request's marker, so
        # it is in this snapshot, or kept if there is none.
        %{output_seam: %{} = seam} ->
          assign(socket,
            snapshot_state: :loading,
            output_seam: %{ref: ref, cut?: false, pre: seam.post ++ seam.pre, post: []}
          )

        _ ->
          assign(socket,
            snapshot_state: :loading,
            output_seam: %{ref: ref, cut?: false, pre: [], post: []}
          )
      end

    socket
    |> assign(:snapshot_ref, ref)
    |> start_async(:snapshot, fn -> {ref, fetch_snapshot(task_id, view, ref)} end)
  end

  # Drops the load in flight when the operator stops the worker: its answer
  # predates the stop. Lines it was holding back are kept.
  defp supersede_snapshot_load(socket) do
    socket
    |> land_output(nil)
    |> assign(snapshot_ref: nil, snapshot_state: :loaded)
  end

  # A worker that is gone by the time we ask is "no worker", as before; one
  # that is there but crashes or times out on the call is the error state.
  defp fetch_snapshot(task_id, view, ref) do
    case Worker.whereis(task_id) do
      nil ->
        nil

      pid ->
        try do
          pid |> Worker.state(view, ref) |> Map.put(:pid, pid)
        catch
          :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] -> nil
          :exit, {{:shutdown, _}, _call} -> nil
        end
    end
  end

  defp receive_output_line(%{assigns: %{output_seam: %{cut?: false} = seam}} = socket, line),
    do: assign(socket, :output_seam, %{seam | pre: [line | seam.pre]})

  defp receive_output_line(%{assigns: %{output_seam: %{cut?: true} = seam}} = socket, line),
    do: assign(socket, :output_seam, %{seam | post: [line | seam.post]})

  # The snapshot has landed but the worker's marker hasn't yet: this line was
  # streamed before the snapshot was taken, so it is already on the page.
  defp receive_output_line(%{assigns: %{output_seam: {:awaiting_cut, _ref}}} = socket, _line),
    do: socket

  defp receive_output_line(socket, line), do: append_output_line(socket, line)

  # Seeds the buffer from a landed snapshot and folds in what streamed while
  # it was in flight: lines after the marker are appended, lines before it are
  # already in the snapshot. With no snapshot to seed from (no worker, or the
  # call failed) every streamed line is kept.
  defp land_output(%{assigns: %{output_seam: %{} = seam}} = socket, snapshot) do
    streamed = Enum.reverse(seam.pre, Enum.reverse(seam.post))

    {lines, seam} =
      case snapshot do
        %{} when seam.cut? -> {snapshot_lines(snapshot) ++ Enum.reverse(seam.post), nil}
        %{} -> {snapshot_lines(snapshot), {:awaiting_cut, seam.ref}}
        nil -> {socket.assigns.output_lines ++ streamed, nil}
      end

    assign(socket, output_lines: Enum.take(lines, -@output_cap), output_seam: seam)
  end

  defp land_output(socket, _snapshot), do: socket

  defp load_details(socket) do
    task_id = socket.assigns.task_id

    # A reload keeps what is on the page until the fresh read lands.
    socket
    |> assign(
      :details_state,
      if(socket.assigns.details_state == :loaded, do: :loaded, else: :loading)
    )
    |> start_async(:details, fn -> load_details_task(task_id) end)
  end

  # The task is linked to this view, so a tab closed mid-read (or a test
  # tearing down) would kill it mid-query — trapping exits turns that into a
  # message instead, so the query in flight finishes rather than dying
  # holding a DB checkout (the shared sandbox one, under test).
  defp load_details_task(task_id) do
    Process.flag(:trap_exit, true)
    result = fetch_details(task_id)

    receive do
      {:EXIT, _view, _reason} -> exit(:shutdown)
    after
      0 -> result
    end
  end

  defp fetch_details(task_id) do
    task = fetch_task(task_id)
    ms = fetch_machine_state(task_id)

    %{
      task: task,
      workspace: fetch_workspace(task),
      machine_state: ms,
      workflow_steps: workflow_steps_for(ms),
      mailbox: fetch_mailbox(task_id),
      latest_run: fetch_latest_run(task_id),
      usage_events: fetch_usage(task_id),
      watchdog: fetch_watchdog(task)
    }
  end

  # bd-741sid: the ticket's Watchdog as the merge panel shows it — whether it
  # is alive, and what it is parked on — read here with everything else, off
  # the LiveView process, rather than by a GenServer hop at render time.
  defp fetch_watchdog(%Issue{state: :merging, id: id}),
    do: %{alive?: Watchdog.alive?(id), parked_on: Watchdog.parked_on(id)}

  defp fetch_watchdog(_task), do: %{alive?: nil, parked_on: nil}

  defp empty_details do
    %{
      task: nil,
      workspace: nil,
      machine_state: nil,
      workflow_steps: [],
      mailbox: [],
      latest_run: nil,
      usage_events: [],
      watchdog: %{alive?: nil, parked_on: nil}
    }
  end

  # bd-741sid: a ticket or PR broadcast re-reads the details — but a read in
  # flight is not restarted, because a newer `start_async/3` supersedes the
  # older task's result, and a Watchdog polling faster than a read lands
  # would starve the page. It is marked stale and read once more when it
  # lands.
  defp reload_details(%{assigns: %{details_reload: reload}} = socket)
       when reload in [:running, :stale],
       do: assign(socket, :details_reload, :stale)

  defp reload_details(socket), do: socket |> assign(:details_reload, :running) |> load_details()

  defp settle_details_reload(%{assigns: %{details_reload: :stale}} = socket),
    do: socket |> assign(:details_reload, :running) |> load_details()

  defp settle_details_reload(socket), do: assign(socket, :details_reload, nil)

  # Subscribes to the loaded task's workspace mailbox topic, once.
  defp subscribe_mailbox(socket) do
    case workspace_id(socket) do
      ws when is_binary(ws) and is_nil(socket.assigns.mailbox_topic) ->
        topic = Message.topic(ws)
        Phoenix.PubSub.subscribe(Arbiter.PubSub, topic)
        assign(socket, :mailbox_topic, topic)

      _ ->
        socket
    end
  end

  defp describe_exit({%{__exception__: true} = error, _stacktrace}), do: Exception.message(error)
  defp describe_exit(reason), do: Exception.format_exit(reason)

  # Re-reads everything off the LiveView process, through the mount's own
  # tasks: no GenServer hop into the worker here, and a load that had failed
  # (or was still running) is retried rather than left on the page.
  defp refresh_all(socket) do
    socket
    |> load_snapshot()
    |> load_details()
  end

  # Most-recent Run row for this task, if any. Used to surface a link from
  # the live worker view to the historical post-mortem of a previous run on
  # the same task.

  defp fetch_latest_run(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  rescue
    _ -> nil
  end

  # Latest usage event(s) for this task — used to surface cost/tokens on the
  # detail page. Queries by task_id, ordered newest-first, capped at 5 rows
  # (one per recent session: work + optional review). Best-effort — nil on error.

  defp fetch_usage(task_id) do
    UsageEvent
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(occurred_at: :desc)
    |> Ash.Query.limit(5)
    |> Ash.read!()
  rescue
    _ -> []
  end

  # Unread mailbox-family messages (mailbox / direction / flag) addressed to
  # this task. Pure read — the operator marks them read explicitly.
  defp refresh_mailbox(socket),
    do: assign(socket, :mailbox, fetch_mailbox(socket.assigns.task_id))

  defp fetch_mailbox(task_id) do
    Message.inbox(task_id)
  rescue
    _ -> []
  end

  # The task's workspace, needed to scope/address messages. nil when the task
  # row is gone (worker outlived its Issue, or a fresh ad-hoc run).
  defp workspace_id(%{assigns: %{task: %Issue{workspace_id: ws}}}) when is_binary(ws), do: ws
  defp workspace_id(_socket), do: nil

  # A run that has not finished (starting, working, or waiting on a question
  # or the review gate) is still working the task. `Dispatch.resume/2`
  # refuses these outright (stop it first), so we don't offer the action.
  #
  # Resume is offered when the task exists and no worker is actively working
  # it — a finished/stopped snapshot, or no snapshot at all (the node
  # restarted, but the worktree may well still be on disk).
  defp active_run?(%{state: state}), do: Arbiter.Workers.RunState.live?(state)
  defp active_run?(_snapshot), do: false

  defp retryable?(nil, _snapshot), do: false
  defp retryable?(%Issue{state: :closed}, _snapshot), do: false
  defp retryable?(%Issue{}, nil), do: true
  defp retryable?(%Issue{}, %{state: _} = snapshot), do: not active_run?(snapshot)
  defp retryable?(_task, _snapshot), do: false

  # A Merging ticket: its PR is open and its Watchdog owns it (bd-741sid).
  defp merging?(%Issue{state: :merging}), do: true
  defp merging?(_task), do: false

  # Whether the "Retry auto-resolve" action makes sense to show at all — a
  # Watchdog parked on an exhausted :ci_failed block (bd-bspakl). Reads the
  # Watchdog's own `park_reason` (via `parked_on/1`, in `fetch_watchdog/1`)
  # rather than inferring from the merger status: `effective_block_reason/1`
  # (arity-1) hardcodes `via_review_gate: false` and so never sees a park
  # reached through the ReviewGate-aware poll loop — exactly the standard
  # Arbiter flow this action targets. `parked_on/1` is authoritative and needs
  # no such inference.
  #
  # `:busy` (mid-poll, `parked_on/1` timed out) is treated as available
  # rather than hidden: hiding it would make the button flicker out at
  # exactly the moment an operator is likely to reach for it, and clicking
  # through to a busy Watchdog surfaces a clear "try again" flash instead.
  # `:ci_failed_external` (bd-5mzzww) is a reclassification of the same park,
  # not a different one: once the infrastructure is fixed, re-arming is the
  # right move, so hiding the button here would strand the task. `:conflict` is
  # an exhausted conflict auto-resolve, which the same action re-arms
  # (bd-4olwyg).
  defp retry_auto_resolve_available?(%Issue{state: :merging}, %{parked_on: reason}),
    do: reason in [:ci_failed, :ci_failed_external, :conflict, :busy]

  defp retry_auto_resolve_available?(_task, _watchdog), do: false

  # A Watchdog is a `:temporary` child: when it crashes it is gone for good and
  # nothing announces it. The ticket stays Merging with an open MR nothing is
  # polling — invisible until someone notices it never merged (bd-8jixav).
  # Surface it here and offer the restart.
  #
  # Only a Merging ticket is checked: in every other state there is no
  # Watchdog expected, so "missing" would be noise. Nor is one pulled out of
  # the merge queue on purpose (`merge_pulled?/2`).
  defp watchdog_missing?(%Issue{state: :merging} = task, %{alive?: false}),
    do: not PullRequest.pulled?(task)

  defp watchdog_missing?(_task, _watchdog), do: false

  # bd-741sid: the operator pulled the PR out of the merge queue
  # (`PullRequest.pull/1`). Nothing polls it on purpose; Restart watchdog puts
  # it back.
  defp merge_pulled?(%Issue{state: :merging} = task, %{alive?: false}),
    do: PullRequest.pulled?(task)

  defp merge_pulled?(_task, _watchdog), do: false

  defp watchdog_restartable?(task, watchdog),
    do: watchdog_missing?(task, watchdog) or merge_pulled?(task, watchdog)

  defp resume_failure(:no_outpost),
    do:
      "the worktree for this task is gone, so there's nothing to resume — " <>
        "dispatch a fresh worker from the ticket page instead."

  defp resume_failure(:repo_unknown),
    do: "no repo could be resolved for this task — dispatch it explicitly instead."

  defp resume_failure({:worker_active, run}),
    do: "a worker is still active (#{run |> run_label() |> String.downcase()}) — stop it first."

  defp resume_failure({:task_closed, _id}), do: "the ticket is closed."

  defp resume_failure({:slot_cap_full, info}),
    do: Arbiter.Worker.ResumeSlot.refusal_message(info)

  defp resume_failure(reason), do: inspect(reason)

  defp start_retry(socket, force?) do
    task_id = socket.assigns.task_id

    opts = [resume_origin: :human, force_slot: force?, slot_override_actor: "dashboard"]

    {:noreply,
     socket
     |> assign(retrying: true, retry_error: nil)
     |> start_async(:retry, fn -> Dispatch.resume(task_id, opts) end)}
  end

  defp fetch_task(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, task} -> task
      _ -> nil
    end
  end

  defp fetch_workspace(%Issue{workspace_id: ws_id}) when is_binary(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  end

  defp fetch_workspace(_task), do: nil

  defp fetch_machine_state(task_id) do
    MachineState
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  rescue
    _ -> nil
  end

  defp workflow_steps_for(nil), do: []

  defp workflow_steps_for(%MachineState{workflow_module: name}) when is_binary(name) do
    mod = Module.safe_concat([name])

    if function_exported?(mod, :steps, 0) do
      Enum.map(mod.steps(), &Atom.to_string/1)
    else
      []
    end
  rescue
    _ -> []
  end

  defp output_topic(task_id), do: "worker:" <> task_id

  # The output buffer a snapshot seeds (`land_output/2`); routine
  # `{:worker_output, _, line}` events append to the buffer rather than
  # re-reading the snapshot, so the page updates with no GenServer hop.
  defp snapshot_lines(%{meta: meta}) when is_map(meta), do: Map.get(meta, :output_lines, []) || []
  defp snapshot_lines(_snapshot), do: []

  defp append_output_line(socket, line) do
    lines =
      (socket.assigns[:output_lines] || [])
      |> Kernel.++([line])
      |> Enum.take(-@output_cap)

    assign(socket, :output_lines, lines)
  end

  # Adapts the plain-string stdout buffer to LogStream's `%{time:, role:,
  # text:}` line shape. Captured lines carry no per-line timestamp/role of
  # their own, so every line is tagged a generic "output" role.
  defp log_stream_lines(lines) do
    Enum.map(lines, &%{time: "", role: "output", text: &1})
  end

  # ---- flow / stop-notice helpers ----

  # Maps a worker snapshot onto one of the four canonical
  # `StatusHelpers.worker_flow/0` steps `<.worker_flow>` understands — the run
  # states themselves, except that a run that finished without succeeding is
  # drawn (reddened) on the step it was on, `:working`.
  defp current_flow_step(%{state: :finished, outcome: outcome})
       when outcome in [:failed, :interrupted],
       do: :working

  defp current_flow_step(%{state: :finished}), do: :finished

  defp current_flow_step(%{state: state}) when state in [:starting, :working, :waiting],
    do: state

  defp current_flow_step(_snapshot), do: :starting

  # The flow step to render: the precise step the worker had reached before
  # a user-initiated stop, when we have one, otherwise derived from the live
  # snapshot's state.
  defp flow_status(%{stopped_flow_step: step}) when not is_nil(step), do: step
  defp flow_status(%{snapshot: snapshot}), do: current_flow_step(snapshot)

  defp flow_failed?(%{snapshot: %{state: :finished, outcome: :failed}}), do: true
  defp flow_failed?(_), do: false

  # `Worker.stop/3` genuinely leaves the worktree in place — it only tears
  # down the GenServer, never touches disk. Keep this claim true if that ever
  # changes.
  defp stop_notice_text(task_id),
    do: "Stop signalled to #{task_id} — the worktree is left in place"

  defp stopped_snapshot(nil), do: nil

  defp stopped_snapshot(snapshot),
    do: Map.merge(snapshot, %{state: :finished, outcome: :failed, waiting_on: nil})

  # ---- toolbar / rail summary helpers ----

  defp snapshot_branch(%{meta: meta}) when is_map(meta), do: Map.get(meta, :branch)
  defp snapshot_branch(_), do: nil

  # "repo · workspace · branch", skipping any part that isn't known yet.
  defp toolbar_context(snapshot, workspace) do
    [snapshot.repo, workspace && workspace.name, snapshot_branch(snapshot)]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp model_label(snapshot) do
    case execution_model(snapshot) do
      nil -> "unknown"
      model -> Arbiter.Agents.ModelDisplay.short(model)
    end
  end

  defp total_tokens(events) do
    case work_events_with_tokens(events) do
      [] -> nil
      evs -> Enum.reduce(evs, 0, fn e, acc -> acc + (e.tokens_in || 0) + (e.tokens_out || 0) end)
    end
  end

  defp total_cost(events) do
    case work_events_with_cost(events) do
      [] -> nil
      evs -> Enum.reduce(evs, 0.0, fn e, acc -> acc + e.cost_usd end)
    end
  end

  defp humanize_tokens(n) when is_integer(n) and n >= 1000,
    do: "#{:erlang.float_to_binary(n / 1000, decimals: 1)}k"

  defp humanize_tokens(n) when is_integer(n), do: to_string(n)

  # "sonnet · 38.4k tok · $0.42" — trailing parts drop off as data arrives.
  defp toolbar_summary(snapshot, usage_events) do
    tokens = total_tokens(usage_events)
    cost = total_cost(usage_events)

    [
      model_label(snapshot),
      tokens && "#{humanize_tokens(tokens)} tok",
      cost && format_usd(cost)
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp dash_if_nil(nil), do: "—"
  defp dash_if_nil(value), do: value

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      quotas={@quotas}
      quota_on_exhaustion={@quota_on_exhaustion}
      open_epic_count={@open_epic_count}
      live={@live}
      coordinator_inbox={@coordinator_inbox}
      coordinator_outstanding_count={@coordinator_outstanding_count}
      coordinator_inbox_now={@coordinator_inbox_now}
    >
      <div class="p-4 sm:p-6 max-w-7xl mx-auto flex flex-col gap-[14px]">
        <%= if @stop_notice do %>
          <.toast
            id="stop-toast"
            tone="error"
            action="resume"
            action_click="open_retry"
            dismiss_key=""
          >
            {stop_notice_text(@task_id)}
          </.toast>
        <% end %>

        <%= cond do %>
          <% @snapshot_state == :loading -> %>
            <.panel>
              <.async_loading id="worker-snapshot-loading" label="Loading worker…" />
            </.panel>
          <% match?({:error, _}, @snapshot_state) -> %>
            <.panel>
              <.async_error
                id="worker-snapshot-error"
                retry_id="worker-snapshot-retry"
                retry="retry_snapshot"
                title="Could not read this worker's state"
                message={elem(@snapshot_state, 1)}
              />
            </.panel>
          <% @snapshot -> %>
            <%!-- ── Worker session — toolbar + log/rail grid (README §5) ──── --%>
            <div class="border border-[var(--border-default)] rounded-[var(--radius-panel)] overflow-hidden">
              <div class="flex flex-wrap items-center gap-[14px] gap-y-2 h-auto px-4 py-2 bg-[var(--surface-chrome)] border-b border-[var(--border-default)]">
                <span class="font-medium text-[12px] text-[var(--text-title)] font-[family-name:var(--font-mono)]">
                  {@task_id}
                </span>
                <Core.copy_id id={@task_id} />
                <.status_chip status={run_status(@snapshot)} />
                <span
                  :if={@snapshot.started_at}
                  class="text-[11.5px] font-mono text-[var(--text-secondary)]"
                >
                  {humanize_seconds(runtime_seconds(@snapshot.started_at, @now))}
                </span>
                <span class="text-[11.5px] text-[var(--text-secondary)] font-[family-name:var(--font-mono)] truncate">
                  {toolbar_context(@snapshot, @workspace)}
                </span>
                <span class="ml-auto flex items-center gap-[10px]">
                  <span class="text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)]">
                    {toolbar_summary(@snapshot, @usage_events)}
                  </span>
                  <%= cond do %>
                    <% active_run?(@snapshot) -> %>
                      <Core.button
                        id="worker-stop-btn"
                        phx-click="stop"
                        data-confirm={"Stop #{@worker_label} for #{@task_id}? Any active Claude subprocess will be terminated."}
                        variant="danger"
                        size="sm"
                      >
                        Stop
                      </Core.button>
                    <% retryable?(@task, @snapshot) -> %>
                      <Core.button
                        id="worker-toolbar-resume-btn"
                        phx-click="open_retry"
                        variant="secondary"
                        size="sm"
                      >
                        Resume
                      </Core.button>
                    <% true -> %>
                  <% end %>
                </span>
              </div>

              <div class="grid gap-px bg-[var(--border-default)] grid-cols-1 lg:grid-cols-[minmax(0,1fr)_272px]">
                <div class="bg-[var(--arb-canvas-sunken)]">
                  <%= if @output_lines == [] do %>
                    <Feedback.empty_state icon="hero-command-line">
                      No output yet.
                    </Feedback.empty_state>
                  <% else %>
                    <.log_stream
                      id="worker-output"
                      live={@snapshot.state == :working}
                      lines={log_stream_lines(@output_lines)}
                      max_height="28rem"
                      bare
                    />
                  <% end %>
                </div>

                <div class="bg-[var(--surface-chrome)] px-4 py-[18px] flex flex-col gap-[18px]">
                  <.worker_flow status={flow_status(assigns)} failed={flow_failed?(assigns)} compact />

                  <.data_list class="text-xs">
                    <:item label="task">
                      <code class="font-mono text-xs">{@task_id}</code>
                      <Core.copy_id id={@task_id} dom_id={"copy-id-worker-detail-#{@task_id}"} />
                    </:item>
                    <:item label="repo">
                      <code class="font-mono text-xs">{dash_if_nil(@snapshot.repo)}</code>
                    </:item>
                    <:item label="branch">
                      <code class="font-mono text-xs">{dash_if_nil(snapshot_branch(@snapshot))}</code>
                    </:item>
                    <:item label="model">
                      <code class="font-mono text-xs">{model_label(@snapshot)}</code>
                    </:item>
                    <:item label="tokens">
                      <code class="font-mono text-xs">
                        {dash_if_nil(
                          total_tokens(@usage_events) && humanize_tokens(total_tokens(@usage_events))
                        )}
                      </code>
                    </:item>
                    <:item label="spend">
                      <code class="font-mono text-xs">
                        {dash_if_nil(
                          total_cost(@usage_events) && format_usd(total_cost(@usage_events))
                        )}
                      </code>
                    </:item>
                  </.data_list>

                  <%!-- `@quotas` is loaded off the mount by `LiveHooks`
                      (bd-adewb4); the top bar carries its loading and error
                      states, so this block just waits for the list. --%>
                  <.async_result :let={quotas} assign={@quotas}>
                    <div :if={quotas != []} id="worker-quota" class="flex flex-col gap-2">
                      <span class="font-medium text-[10.5px] tracking-[var(--tracking-eyebrow)] uppercase text-[var(--text-label)] font-[family-name:var(--font-mono)]">
                        Quota
                      </span>
                      <.quota_bar
                        :for={{w, i} <- Enum.with_index(QuotaHelpers.quota_windows(hd(quotas)))}
                        provider={hd(quotas).provider}
                        show_label={i == 0}
                        window={w.window}
                        label={w.label}
                        utilization={w.utilization}
                        reset_at={w.reset_at}
                        overage_status={hd(quotas).overage_status}
                        representative_claim={hd(quotas).representative_claim}
                        stale_message={hd(quotas).message}
                        gate_policy={Map.get(hd(quotas), :gate_policy)}
                        width={140}
                      />
                    </div>
                  </.async_result>

                  <div class="flex flex-col gap-[7px]">
                    <span class="font-medium text-[10.5px] tracking-[var(--tracking-eyebrow)] uppercase text-[var(--text-label)] font-[family-name:var(--font-mono)]">
                      Actions
                    </span>
                    <Core.button
                      id="worker-resume-note-btn"
                      phx-click="open_retry"
                      size="sm"
                      disabled={!retryable?(@task, @snapshot)}
                    >
                      <:icon><Core.icon name="hero-arrow-path" size={12} /></:icon>
                      Resume with note
                    </Core.button>
                    <%= if @latest_run do %>
                      <Core.button
                        size="sm"
                        variant="ghost"
                        phx-click={JS.navigate(~p"/workers/history/#{@latest_run.id}")}
                      >
                        <:icon><Core.icon name="hero-clipboard-document-list" size={12} /></:icon>
                        Full transcript
                      </Core.button>
                    <% else %>
                      <Core.button size="sm" variant="ghost" disabled>
                        <:icon><Core.icon name="hero-clipboard-document-list" size={12} /></:icon>
                        Full transcript
                      </Core.button>
                    <% end %>
                  </div>
                </div>
              </div>
            </div>

            <%!-- ── Waiting on you panel (the agent asked a question) ───── --%>
            <.panel
              :if={@snapshot.state == :waiting and @snapshot.waiting_on == :question}
              title="Waiting on you"
            >
              <:actions>
                <.status_chip status={:waiting} />
              </:actions>
              <p class="text-sm text-[var(--text-secondary)]">
                This {@worker_label} has paused and is waiting for a human decision before it can proceed.
              </p>
              <%= if ref = mr_ref(@snapshot) do %>
                <a
                  href={ref}
                  target="_blank"
                  rel="noopener"
                  class="inline-flex items-center gap-[7px] mt-2 rounded-[var(--radius-field)] border border-solid font-medium h-[var(--control-sm)] px-[10px] text-[11.5px] bg-[var(--arb-attention)] border-[var(--arb-attention)] text-[var(--arb-attention-ink)] hover:brightness-[1.06] transition-[background,border-color] duration-[var(--dur-hover)] ease-[var(--arb-ease-out)]"
                >
                  <Core.icon name="hero-arrow-top-right-on-square" size={14} /> Open {@pr_label}
                  <code class="font-mono text-xs opacity-80">{ref}</code>
                </a>
              <% else %>
                <p class="text-sm text-[var(--text-label)] italic flex items-center gap-1.5 mt-2">
                  <Core.icon name="hero-link-slash" size={14} /> No {@pr_label} ref recorded yet.
                </p>
              <% end %>
            </.panel>

            <%!-- ── Details ─────────────────────────────────────────────── --%>
            <.panel title="Details">
              <div class="flex flex-wrap justify-between items-start gap-4">
                <.data_list class="text-sm">
                  <:item :if={claude_session?(@snapshot)} label="Activity">
                    {live_activity(@snapshot)}
                  </:item>
                  <:item :if={!claude_session?(@snapshot)} label="Current step">
                    <code class="font-mono text-xs">{@snapshot.current_step}</code>
                  </:item>
                  <:item label={String.capitalize(@workspace_label)}>
                    <%= if @workspace do %>
                      {@workspace.name}
                      <span class="text-[var(--text-label)]">
                        (<code class="font-mono text-xs">{@workspace.prefix}</code>)
                      </span>
                    <% else %>
                      <span class="text-[var(--text-label)]">(none)</span>
                    <% end %>
                  </:item>
                  <:item label="Provider">
                    <span class="inline-flex items-center gap-1.5">
                      <.provider_icon provider={Worker.provider(@snapshot.meta)} class="size-4" />
                      <code class="font-mono text-xs">
                        {provider_display_name(Worker.provider(@snapshot.meta))}
                      </code>
                    </span>
                  </:item>
                  <:item label="Runs on">
                    <.run_where
                      node_name={RunNode.node_name(@snapshot)}
                      id="worker-detail-where"
                      class="text-xs"
                    />
                  </:item>
                  <:item :if={thinking = execution_thinking(@snapshot)} label="Reasoning effort">
                    <code class="font-mono text-xs">{thinking}</code>
                  </:item>
                  <:item :if={tier = execution_model_tier(@snapshot)} label="Model tier">
                    <code class="font-mono text-xs">{tier}</code>
                  </:item>
                  <:item label="Started">
                    <span class="font-mono text-xs tabular-nums">
                      {format_ts_long(@snapshot.started_at)}
                    </span>
                  </:item>
                  <:item label="Elapsed">
                    <span class="font-mono text-xs tabular-nums">
                      {humanize_seconds(runtime_seconds(@snapshot.started_at, @now))}
                    </span>
                  </:item>
                  <:item
                    :if={exit_status = Map.get(@snapshot.meta || %{}, :exit_status)}
                    label="Exit status"
                  >
                    <span class="font-mono text-xs">{exit_status}</span>
                  </:item>
                  <:item :if={result = Map.get(@snapshot.meta || %{}, :result)} label="Result">
                    <span class="font-mono text-xs">{inspect(result)}</span>
                  </:item>
                  <:item
                    :if={reason = Map.get(@snapshot.meta || %{}, :failure_reason)}
                    label="Failure"
                  >
                    <span class="text-[var(--arb-fail-text)] font-mono text-xs">
                      {inspect(reason)}
                    </span>
                  </:item>
                </.data_list>

                <div class="flex flex-col gap-2 shrink-0">
                  <Core.button
                    variant="ghost"
                    size="sm"
                    phx-click={JS.navigate(~p"/tasks/#{@task_id}")}
                  >
                    <:icon><Core.icon name="hero-arrow-top-right-on-square" size={14} /></:icon>
                    {String.capitalize(@issue_label)} detail
                  </Core.button>
                  <Core.button
                    :if={@latest_run}
                    variant="ghost"
                    size="sm"
                    phx-click={JS.navigate(~p"/workers/history/#{@latest_run.id}")}
                  >
                    <:icon><Core.icon name="hero-archive-box" size={14} /></:icon>
                    Run history
                  </Core.button>
                </div>
              </div>
            </.panel>

            <%!-- ── Assigned task summary ─────────────────────────────── --%>
            <.panel :if={@task} title={"#{String.capitalize(@issue_label)}: #{@task.title}"}>
              <.data_list class="text-sm">
                <:item :if={@task.target_branch} label="Target branch">
                  <code class="font-mono text-xs">{@task.target_branch}</code>
                </:item>
                <:item :if={@task.difficulty} label="Difficulty">
                  <.difficulty_meter difficulty={@task.difficulty} />
                </:item>
                <:item :if={@task.priority} label="Priority">
                  <.priority_tag priority={@task.priority} />
                </:item>
                <:item :if={@task.issue_type} label="Type">
                  <.type_tag type={@task.issue_type} />
                </:item>
                <:item :if={tracker_display(@task)} label="Tracker">
                  <span class="font-mono text-xs">{tracker_display(@task)}</span>
                </:item>
              </.data_list>
            </.panel>

            <%!-- ── Worker metadata ───────────────────────────────────── --%>
            <.panel :if={meta_has_details?(@snapshot.meta)} title="Metadata">
              <.data_list class="text-sm">
                <:item :if={role = Map.get(@snapshot.meta || %{}, :role)} label="Role">
                  {role}
                </:item>
                <:item :if={Map.get(@snapshot.meta || %{}, :review_required)} label="Review gate">
                  <.status_chip status="required" />
                </:item>
                <:item :if={path = Map.get(@snapshot.meta || %{}, :worktree_path)} label="Worktree">
                  <span class="font-mono text-xs break-all">{path}</span>
                </:item>
                <:item :if={branch = Map.get(@snapshot.meta || %{}, :branch)} label="Branch">
                  <code class="font-mono text-xs">{branch}</code>
                </:item>
                <:item :if={@snapshot.step_started_at} label="Step started">
                  <span class="font-mono text-xs tabular-nums">
                    {format_ts_long(@snapshot.step_started_at)}
                  </span>
                </:item>
                <:item :if={reason = Map.get(@snapshot.meta || %{}, :stop_reason)} label="Stop reason">
                  <span class="text-[var(--arb-fail-text)] text-xs font-mono">
                    {Map.get(reason, :summary) || inspect(reason)}
                  </span>
                </:item>
              </.data_list>
            </.panel>

            <%!-- ── Live activity (claude-driven) ──────────────────────── --%>
            <%!-- A claude-driven worker does the real work in a streaming --%>
            <%!-- subprocess; its Driver never ticks the workflow Machine, so --%>
            <%!-- the fixed load_context→submit steps would sit frozen. Show --%>
            <%!-- the live activity derived from the stream instead (bd-c919xj). --%>
            <.panel :if={claude_session?(@snapshot)} title="Live activity">
              <div class="flex items-center gap-2">
                <span class="text-[13px] font-medium text-[var(--text-title)]">
                  {live_activity(@snapshot)}
                </span>
              </div>
              <p class="text-xs text-[var(--text-label)] mt-1">
                Driven by {live_activity_driven_by(@snapshot)} — progress streams in the output above rather than
                advancing fixed workflow steps.
              </p>
            </.panel>

            <.panel :if={@machine_state && not claude_session?(@snapshot)} title="Workflow">
              <:actions>
                <code class="text-xs font-mono text-[var(--text-label)]">
                  {short_module(@machine_state.workflow_module)}
                </code>
              </:actions>
              <div class="flex flex-wrap gap-1.5">
                <span
                  :for={step <- @workflow_steps}
                  class={["badge", step_class(step, @machine_state)]}
                >
                  {step}
                </span>
              </div>
              <p class="text-xs text-[var(--text-label)] mt-2">
                Machine status: <strong>{@machine_state.status}</strong>
                · current step: <code class="font-mono">{@machine_state.current_step}</code>
              </p>
            </.panel>
          <% true -> %>
            <.panel>
              <Feedback.empty_state
                icon="hero-signal-slash"
                detail={
                  if merging?(@task),
                    do:
                      "Its #{@pr_label} is open, and the merge watchdog below watches it — no worker stays on it.",
                    else: "It may have stopped, or the Phoenix node was restarted since it ran."
                }
              >
                No {@worker_label} registered for {@issue_label} <code class="font-mono">{@task_id}</code>.
              </Feedback.empty_state>
              <div :if={retryable?(@task, @snapshot)} class="flex justify-center mt-3">
                <Core.button
                  id="worker-fallback-resume-btn"
                  phx-click="open_retry"
                  variant="secondary"
                  size="sm"
                >
                  <:icon><Core.icon name="hero-arrow-path" size={14} /></:icon>
                  Resume
                </Core.button>
              </div>
            </.panel>
        <% end %>

        <%!-- ── Merge request: the ticket's (bd-741sid) ─────────────── --%>
        <.panel :if={merging?(@task)} id="worker-merge-request" title="Merge request">
          <%!-- bd-8jixav: a Watchdog is a :temporary process — when it dies --%>
          <%!-- it is gone silently, and the fields below go stale forever --%>
          <%!-- while still looking live. Say so before showing them. --%>
          <div
            :if={watchdog_missing?(@task, @watchdog)}
            id="worker-no-watchdog-warning"
            class="flex items-start gap-2 mb-3 rounded-[var(--radius-field)] border border-solid border-[var(--arb-attention)] bg-[color-mix(in_oklab,var(--arb-attention)_12%,transparent)] px-[10px] py-2"
          >
            <Core.icon
              name="hero-exclamation-triangle"
              size={14}
              class="mt-[2px] text-[var(--arb-attention)]"
            />
            <div class="text-[12.5px] leading-[1.5]">
              <span class="font-medium text-[var(--text-title)]">
                No watchdog is running for this task.
              </span>
              <span class="text-[var(--text-secondary)]">
                The {@pr_label} is still open but nothing is polling it, so it will never
                merge on its own. The values below are frozen at the last poll. Use
                <span class="font-medium">Restart watchdog</span>
                to start a replacement on the same {@pr_label}.
              </span>
            </div>
          </div>
          <%!-- bd-741sid: pulled out of the merge queue on purpose — not an alarm. --%>
          <div
            :if={merge_pulled?(@task, @watchdog)}
            id="worker-merge-pulled-notice"
            class="flex items-start gap-2 mb-3 rounded-[var(--radius-field)] border border-solid border-[var(--border-default)] bg-[var(--arb-canvas-sunken)] px-[10px] py-2"
          >
            <Core.icon
              name="hero-pause-circle"
              size={14}
              class="mt-[2px] text-[var(--text-label)]"
            />
            <div class="text-[12.5px] leading-[1.5]">
              <span class="font-medium text-[var(--text-title)]">
                Pulled out of the merge queue.
              </span>
              <span class="text-[var(--text-secondary)]">
                The {@pr_label} is still open, and nothing merges it on its own. The values
                below are frozen at the last poll. Use
                <span class="font-medium">Restart watchdog</span>
                to put it back in the queue.
              </span>
            </div>
          </div>
          <.data_list class="text-sm">
            <:item label="MR">
              <%= if @task.merger_url do %>
                <a href={@task.merger_url} target="_blank" rel="noopener" class="hover:underline">
                  {@task.pr_ref} ↗
                </a>
              <% else %>
                <code class="font-mono text-xs">{@task.pr_ref}</code>
              <% end %>
            </:item>
            <:item label="Approval">
              <%= if merger_status = PullRequest.merger_status(@task) do %>
                <span class={["badge", approval_class(merger_status)]}>
                  {approval_label(merger_status)}
                </span>
              <% else %>
                <span class="text-[var(--text-label)]">awaiting first poll…</span>
              <% end %>
            </:item>
            <:item label="Poll interval">{div(Watchdog.default_interval_ms(), 1000)}s</:item>
            <:item label="Last checked">
              <%= case @task.merger_checked_at do %>
                <% %DateTime{} = ts -> %>
                  <span class="font-mono text-xs tabular-nums">
                    {Calendar.strftime(ts, "%Y-%m-%d %H:%M:%S UTC")}
                  </span>
                <% _ -> %>
                  <span class="text-[var(--text-label)]">never</span>
              <% end %>
            </:item>
          </.data_list>
          <div
            :if={
              watchdog_restartable?(@task, @watchdog) or
                retry_auto_resolve_available?(@task, @watchdog)
            }
            class="flex flex-wrap items-center gap-2 mt-3"
          >
            <Core.button
              :if={watchdog_restartable?(@task, @watchdog)}
              id="worker-restart-watchdog-btn"
              phx-click="restart_watchdog"
              data-confirm={"Start a fresh merge watchdog for #{@task_id}, attached to its open #{@pr_label}? Nothing is polling it right now."}
              size="sm"
              disabled={@restarting_watchdog}
            >
              <:icon><Core.icon name="hero-bolt" size={12} /></:icon>
              {if @restarting_watchdog, do: "Restarting watchdog…", else: "Restart watchdog"}
            </Core.button>
            <Core.button
              :if={retry_auto_resolve_available?(@task, @watchdog)}
              id="worker-retry-auto-resolve-btn"
              phx-click="retry_auto_resolve"
              data-confirm={"Re-arm one more auto-resolve attempt for #{@task_id}? This dispatches a fresh fix-pass worker."}
              size="sm"
            >
              <:icon><Core.icon name="hero-arrow-path" size={12} /></:icon>
              Retry auto-resolve
            </Core.button>
          </div>
        </.panel>

        <%!-- ── Mailbox + compose ──────────────────────────────────── --%>
        <div id="mailbox">
          <.panel
            title="Mailbox"
            meta={if(@details_state == :loaded, do: "#{length(@mailbox)} unread")}
          >
            <%= cond do %>
              <% @details_state == :loading -> %>
                <.async_loading id="worker-details-loading" label="Loading task details…" />
              <% match?({:error, _}, @details_state) -> %>
                <.async_error
                  id="worker-details-error"
                  retry_id="worker-details-retry"
                  retry="retry_details"
                  title="Could not load this task's details"
                  message={elem(@details_state, 1)}
                />
              <% @mailbox == [] -> %>
                <div id="mailbox-empty">
                  <Feedback.empty_state icon="hero-inbox">
                    No unread mail.
                  </Feedback.empty_state>
                </div>
              <% true -> %>
                <ul class="flex flex-col gap-2" id="mailbox-list">
                  <li
                    :for={m <- @mailbox}
                    class="rounded-[var(--radius-field)] bg-[var(--surface-card)] border border-[var(--border-default)] p-3"
                  >
                    <div class="flex items-baseline justify-between gap-2">
                      <div class="flex items-baseline gap-2 flex-wrap min-w-0">
                        <span class={["badge shrink-0", kind_badge_class(m.kind)]}>
                          {m.kind}
                        </span>
                        <span class="text-xs text-[var(--text-label)]">
                          from <code class="font-mono">{m.from_ref || "?"}</code>
                        </span>
                        <span :if={m.subject} class="text-sm font-medium truncate">{m.subject}</span>
                      </div>
                      <Core.button phx-click="mark_read" phx-value-id={m.id} variant="ghost" size="sm">
                        Mark read
                      </Core.button>
                    </div>
                    <p class="text-sm mt-1.5 whitespace-pre-wrap text-[var(--text-secondary)]">
                      {m.body}
                    </p>
                  </li>
                </ul>
            <% end %>

            <form
              phx-submit="send_direction"
              phx-change="compose_change"
              class="flex flex-col gap-2 pt-3 mt-1 border-t border-[var(--border-default)]"
            >
              <label class="text-sm font-medium flex items-center gap-1.5">
                <Core.icon name="hero-paper-airplane" size={14} /> Send direction to
                <code class="font-mono">{@task_id}</code>
                (from coordinator)
              </label>
              <textarea
                name="body"
                rows="3"
                placeholder="e.g. check the API contract before refactoring"
                class="w-full text-sm rounded-[var(--radius-field)] border border-[var(--border-default)] bg-[var(--surface-field)] px-3 py-2"
              >{@compose_body}</textarea>
              <div>
                <Core.button type="submit" variant="primary" size="sm" disabled={is_nil(@workspace)}>
                  <:icon><Core.icon name="hero-paper-airplane" size={14} /></:icon>
                  Send direction
                </Core.button>
              </div>
            </form>
          </.panel>
        </div>

        <Navigation.back_link href={~p"/"} label="Back to board" />
      </div>

      <%!-- Resume modal. Confirming re-spawns an agent, so this is the
           confirmation step for a credit-spending action — same contract as
           the dispatch modal on the issue page. --%>
      <div :if={@retry_modal} class="modal modal-open" id="worker-retry-modal">
        <div class="modal-box">
          <h3 class="font-semibold text-lg mb-1">Resume {@task_id}</h3>
          <p class="text-sm text-base-content/70 mb-3">
            Attaches a <strong>fresh</strong>
            agent to the preserved worktree, briefed with a summary of what the
            stopped run already committed — it continues rather than starting over.
          </p>

          <div role="alert" class="alert alert-warning py-2 mb-3">
            <Core.icon name="hero-exclamation-triangle" size={20} />
            <span class="text-sm">
              This spends real <strong>API credits</strong>. If the worktree is gone,
              the resume is refused rather than silently starting from scratch.
            </span>
          </div>

          <p
            :if={@retrying}
            id="worker-retry-pending"
            class="text-sm text-base-content/70 flex items-center gap-2 mb-2"
          >
            <span class="loading loading-spinner loading-xs"></span>
            Resuming — checking provider auth and quota, then attaching a fresh agent. Don't close this tab.
          </p>
          <p :if={@retry_error} class="text-sm text-error mb-2">{@retry_error}</p>

          <div class="modal-action">
            <Core.button
              type="button"
              phx-click="cancel_retry"
              variant="ghost"
              size="sm"
              disabled={@retrying}
            >
              Cancel
            </Core.button>
            <%!-- bd-92mx1m: offered only after the cap refused the plain
                 resume, so going over it is always a deliberate second click. --%>
            <Core.button
              :if={@retry_over_cap}
              id="worker-retry-force-btn"
              phx-click="retry_force"
              variant="attention"
              size="sm"
              disabled={@retrying}
            >
              Resume over the cap
            </Core.button>
            <Core.button phx-click="retry" variant="primary" size="sm" disabled={@retrying}>
              {if @retrying, do: "Resuming…", else: "Resume"}
            </Core.button>
          </div>
        </div>
        <div class="modal-backdrop" phx-click="cancel_retry"></div>
      </div>
    </Layouts.app>
    """
  end

  # Badge color + text for the last Mergers.get/1 result the Watchdog recorded.
  # An *approved* MR that still can't merge (#354, Phase 1) surfaces the *why*
  # ahead of the generic approval state. The block reason is read through
  # `Watchdog.effective_block_reason/1`, which only reports a block once the MR
  # is approved — so the ordinary pre-approval review window never shows a red
  # "Blocked" badge.
  def approval_class(%{status: :merged}), do: "badge-success"
  def approval_class(%{status: :closed}), do: "badge-error"

  def approval_class(status) when is_map(status) do
    cond do
      Watchdog.effective_block_reason(status) -> "badge-error"
      Map.get(status, :approved) == true -> "badge-success"
      Watchdog.ci_pending?(status) -> "badge-info"
      true -> "badge-warning"
    end
  end

  def approval_class(_), do: "badge-warning"

  # bd-c5m9b5: the in-flight and failed states of the two async loads.
  attr :id, :string, required: true
  attr :label, :string, required: true

  defp async_loading(assigns) do
    ~H"""
    <div
      id={@id}
      role="status"
      class="flex items-center gap-2 py-3 text-[12.5px] text-[var(--text-secondary)]"
    >
      <Core.icon name="hero-arrow-path-micro" class="size-4 shrink-0 animate-spin" />
      {@label}
    </div>
    """
  end

  attr :id, :string, required: true
  attr :retry_id, :string, required: true
  attr :retry, :string, required: true, doc: "the phx-click event that restarts the load"
  attr :title, :string, required: true
  attr :message, :string, required: true

  defp async_error(assigns) do
    ~H"""
    <div
      id={@id}
      role="alert"
      class="flex items-start gap-3 rounded-[var(--radius-field)] border border-solid border-[var(--arb-fail-edge)] bg-[var(--arb-fail-wash)] p-4 text-[12.5px] text-[var(--arb-fail-text)]"
    >
      <Core.icon
        name="hero-exclamation-triangle"
        class="mt-0.5 size-5 shrink-0 text-[var(--arb-fail-text)]"
      />
      <div class="min-w-0 grow">
        <p class="m-0 font-medium">{@title}</p>
        <p class="m-0 mt-1 text-[12px] opacity-90 break-words">{@message}</p>
      </div>
      <button
        type="button"
        id={@retry_id}
        phx-click={@retry}
        class={[
          "h-[28px] shrink-0 cursor-pointer rounded-[var(--radius-field)] px-3",
          "border border-solid border-[var(--arb-fail-edge)] bg-[var(--surface-chrome)]",
          "text-[12px] text-[var(--text-secondary)] transition-colors hover:text-[var(--text-primary)]"
        ]}
      >
        Retry
      </button>
    </div>
    """
  end

  def approval_label(%{status: :merged}), do: "Merged"
  def approval_label(%{status: :closed}), do: "Closed"

  def approval_label(status) when is_map(status) and not is_struct(status) do
    case Watchdog.effective_block_reason(status) do
      nil -> approval_label_default(status)
      reason -> block_reason_label(reason)
    end
  end

  def approval_label(_), do: "Pending"

  defp approval_label_default(%{approved: true}), do: "Approved"

  defp approval_label_default(%{status: :open} = status) do
    if Watchdog.ci_pending?(status) do
      "Open · CI running"
    else
      "Open · awaiting approval"
    end
  end

  defp approval_label_default(%{status: status}) when is_atom(status),
    do: status |> Atom.to_string() |> String.capitalize()

  defp approval_label_default(_), do: "Pending"

  # Human label for a Watchdog block reason (#354, Phase 1).
  defp block_reason_label(:conflict), do: "Blocked · conflict"
  defp block_reason_label(:behind_base), do: "Blocked · behind base"
  defp block_reason_label(:ci_failed), do: "Blocked · CI failed"
  defp block_reason_label(:needs_approval), do: "Blocked · needs approval"

  defp block_reason_label(:needs_nonauthor_approval),
    do: "Parked · awaiting human reviewer"

  defp block_reason_label(:draft), do: "Blocked · draft"
  defp block_reason_label(:blocked_other), do: "Blocked"
  defp block_reason_label(other), do: "Blocked · #{other}"

  # A claude-driven worker (a streaming Claude subprocess does the real work).
  # Flagged on meta at session-open. Such a worker's workflow Machine is never
  # ticked, so the fixed steps are meaningless — show live activity instead.
  defp claude_session?(%{meta: meta}) when is_map(meta),
    do: Map.get(meta, :claude_session) == true

  defp claude_session?(_), do: false

  defp live_activity(%{meta: meta}) when is_map(meta) do
    case Map.get(meta, :activity) do
      %{"label" => label} when is_binary(label) -> label
      %{label: label} when is_binary(label) -> label
      label when is_binary(label) -> label
      _ -> "working"
    end
  end

  defp live_activity(_), do: "working"

  defp live_activity_driven_by(%{meta: meta}) when is_map(meta) do
    live_activity_driven_by_provider(Worker.provider(meta))
  end

  defp live_activity_driven_by(_), do: "a live agent session"

  defp live_activity_driven_by_provider(nil), do: "a live agent session"

  defp live_activity_driven_by_provider(provider) do
    if provider in ArbiterWeb.CoreComponents.ProviderIcon.__known_providers__() do
      "a live #{display_name(provider)} session"
    else
      "a live agent session"
    end
  end

  # Color a workflow step based on whether it's done, current, or upcoming.
  defp step_class(step, %MachineState{completed_steps: completed, current_step: current}) do
    cond do
      step in (completed || []) -> "badge-success"
      step == current -> "badge-info"
      true -> "badge-ghost"
    end
  end

  defp step_class(_, _), do: "badge-ghost"

  defp short_module(name) when is_binary(name) do
    case String.split(name, ".") do
      [] -> name
      parts -> Enum.take(parts, -2) |> Enum.join(".")
    end
  end

  defp short_module(_), do: ""

  # ---- shared visual helpers (mirrors DashboardLive for an identical look) ----

  defp runtime_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second) |> max(0)
  end

  defp runtime_seconds(_, _), do: 0

  defp humanize_seconds(s) when s < 60, do: "#{s}s"
  defp humanize_seconds(s) when s < 3600, do: "#{div(s, 60)}m"
  defp humanize_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  # An MR/PR ref is not currently persisted on the worker snapshot, so this
  # degrades to nil. When the dispatch flow starts stashing it in meta (under
  # :mr_ref or "mr_ref"), the awaiting-review link lights up automatically.
  defp mr_ref(%{meta: meta}) when is_map(meta) do
    Map.get(meta, :mr_ref) || Map.get(meta, "mr_ref")
  end

  defp mr_ref(_), do: nil

  # A registered-but-unmapped provider string (e.g. a future adapter added
  # before its logo lands) shows as itself rather than collapsing to the
  # "Unknown provider" fallback, which is reserved for nil/unrecognized
  # meta so the raw value stays visible for diagnosis.
  defp provider_display_name(nil), do: display_name(nil)

  defp provider_display_name(provider) do
    if provider in ArbiterWeb.CoreComponents.ProviderIcon.__known_providers__() do
      display_name(provider)
    else
      provider
    end
  end

  # ---- execution context helpers ----------------------------------------

  # Model: prefer the ACTUAL model from the running session (synced from the
  # Claude streaming init event — exact concrete model name), then fall back to
  # the configured model from the routing decision.
  defp execution_model(%{meta: meta}) when is_map(meta) do
    Map.get(meta, :model) || get_in(meta, [:routing_config, :model])
  end

  defp execution_model(_), do: nil

  defp execution_thinking(%{meta: meta}) when is_map(meta) do
    get_in(meta, [:routing_config, :thinking])
  end

  defp execution_thinking(_), do: nil

  defp execution_model_tier(%{meta: meta}) when is_map(meta) do
    get_in(meta, [:routing_config, :model_tier])
  end

  defp execution_model_tier(_), do: nil

  defp work_events_with_cost(events) do
    Enum.filter(events, &(&1.step == :work && not is_nil(&1.cost_usd)))
  end

  defp work_events_with_tokens(events) do
    Enum.filter(events, &(&1.step == :work && not is_nil(&1.tokens_in)))
  end

  # Tracker ref display: "jira:ABC-123", "github:42", etc.
  defp tracker_display(%Issue{tracker_type: type, tracker_ref: ref})
       when not is_nil(ref) and ref != "" and type not in [nil, :none] do
    "#{type}:#{ref}"
  end

  defp tracker_display(_), do: nil

  # Whether the meta map has any details worth showing in the metadata section.
  defp meta_has_details?(nil), do: false

  defp meta_has_details?(meta) when is_map(meta) do
    Enum.any?(
      [:role, :review_required, :worktree_path, :branch, :stop_reason],
      &Map.has_key?(meta, &1)
    )
  end
end
