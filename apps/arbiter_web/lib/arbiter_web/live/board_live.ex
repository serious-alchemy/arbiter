defmodule ArbiterWeb.BoardLive do
  @moduledoc """
  The board — the home screen, and the only page that answers "what is the
  fleet doing" in one look.

  Five columns for where a piece of work actually sits: **Backlog**,
  **Ready**, **Running**, **Waiting**, **Closed · last 24h**. They are stages, not
  statuses — the task FSM still only knows `open` / `in_progress` / `closed`,
  and every column is derived from worker state, review state, merge-queue
  membership and the issue's `refined` flag by `Arbiter.Board.Snapshot`.
  Nothing here is stored, so nothing here can drift.

  ## Backlog is where work is born

  Every new issue lands in Backlog (bd-b5wyjd) — `arb create`, `task_create`,
  the REST API and the dashboard form alike. It is the pile of things somebody
  wrote down, ordered newest-first because an unrefined pile is a
  to-think-about list rather than a second queue; nothing in it is a candidate
  for dispatch and no card in it carries a scheduler reason.

  There is exactly one door out, and it is not on this screen: the task detail
  page's **Move to Ready** button, which flips `refined` and nothing else.
  Backlog cards are deliberately not draggable — promotion is a decision made
  while looking at the ticket, not while looking at five columns of them, and
  a drag-to-promote gesture can be added later once the button has taught us
  what promotion actually needs to check.

  Backlog is a *refinement* surface, not a scheduling one, which is why it
  ignores dependencies entirely. A refined card whose blocker is still open
  stays in Ready wearing its `blocked — waiting on bd-9` reason: blocked is a
  scheduling fact, unrefined is a refinement fact, and a card can be either
  without being the other.

  ## Waiting is one column, and the flag is the only split

  Waiting was two — Needs you and Merge queue — until bd-crn03r merged them.
  Both held cards whose worker was done and whose outcome hung on something
  external, and splitting them by *what* is external (a person vs. a poll)
  drew a line the operator never acts on. The line that matters is narrower:
  has the system run out of things to try? `Arbiter.Board.Snapshot` answers
  that per card as `:needs_you`, and this screen renders it as one small flag
  in the card header — not a hue, not an accent rule, not a column of its own.
  Everything else in the column reads as plain pipeline-wait.

  ## Ready is a queue, not a parking lot

  The design handoff put a *drop to dispatch* zone at the foot of the Ready
  column: cards sat there until a human dragged each one into Running. This
  screen deliberately does not build that (bd-bqyeqa). An operator who must
  drag every card into flight is a scheduler made of a person, and a person is
  the one component here that cannot watch sixteen slots at once.

  Instead `Arbiter.Board.Scheduler` decides and `Arbiter.Board.Autopilot`
  dispatches: the top eligible Ready card is promoted whenever a worker slot
  frees up, gated on dependency blocks, file overlap with in-flight work, quota
  headroom and a pause switch. Every Ready card therefore carries a *reason*
  rather than a static state — `next up — dispatching...`, `2 ahead in queue`,
  `blocked — waiting on bd-9`, `blocked — quota exhausted`. A queue that
  explains itself is one an operator can leave alone.

  ## What drag is still for

  Drag remains a human action, for the moves only a human can decide:

    * **reordering within Ready** — not yet. The queue is in priority, then
      rank order (bd-asxw4e), which is the order Autopilot dispatches in; a
      session-only hand-ranking used to reorder the cards here while
      Autopilot ignored it. Until drag-to-rank writes the rank (bd-79w1fs),
      a reorder is answered with that explanation and changes nothing;
    * **pulling a card out of Running** — stops the worker, and asks first,
      because that kills a live agent mid-thought;
    * **Waiting outcomes** — dropping a Waiting card on Ready sends the work
      back (the halted worker is discarded and the issue returns to the queue
      for the scheduler to re-decide); dropping it forward, toward Closed,
      means "carry on" — a parked worker un-parks and finishes its own way to
      a merge request, while a card already sitting on one is pulled out of
      the queue (the worker stops; the merge request itself is untouched).
      The worker FSM has the final say on the first.

  Dragging *into* Running is refused with an explanation. There is no hidden
  manual path into flight: if a card is not being promoted, the reason on its
  face is the thing to fix.

  ## Component shadowing

  `ArbiterWeb`'s html helpers import the redesigned component groups with
  exclusions where a name collides with the pre-redesign `core_components.ex`
  (`button/1`, `icon/1`, `input/1`, `select/1`, `empty_state/1`, ...). Those
  are called fully-qualified here so this screen gets the redesigned component
  and not the daisyUI one, until bd-3z2txy retires the shim.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Board.Autopilot
  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.PullRequest
  alias Arbiter.Worker
  alias Arbiter.Worker.ResumeSlot
  alias Arbiter.Worker.Watchdog

  @tasks_topic "tasks"
  @workers_topic "workers"

  # How many cards a column shows before it collapses into an "N more" row.
  @column_limit 8

  # Every call this LiveView makes out to another process is bounded. Nothing
  # on the render path may hang the operator's only view of the fleet.
  @scheduler_call_timeout_ms 2_000
  @stop_timeout_ms 5_000

  @columns [
    %{key: "backlog", label: "Backlog", tone: nil},
    %{key: "ready", label: "Ready", tone: nil},
    %{key: "running", label: "Running", tone: "live"},
    %{key: "waiting", label: "Waiting", tone: nil},
    %{key: "closed", label: "Closed · last 24h", tone: nil}
  ]

  @impl true
  def mount(_params, _session, socket) do
    live? = connected?(socket)

    if live? do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @tasks_topic)
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @workers_topic)
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Autopilot.topic())
      # Elapsed counters on Running cards, and the wait times the Waiting
      # column is ordered by. Reassigns `:now` only — no reads.
      :timer.send_interval(1000, self(), :tick)
    end

    now = DateTime.utc_now()

    # The board itself arrives by `start_async/3` on the connected mount only
    # (bd-15bn6s): the dead render reads nothing and draws a skeleton, and the
    # empty snapshot is only there so the render never has to ask whether a
    # board exists yet.
    socket =
      socket
      |> assign(:page_title, "Board")
      |> assign(:live, live?)
      |> assign(:now, now)
      |> assign(:filter, "")
      |> assign(:workspace, "all")
      |> assign(:expanded, MapSet.new())
      |> assign(:confirm_stop, nil)
      |> assign(:columns, @columns)
      |> assign(:issue_label, "issue")
      |> assign(:worker_label, "worker")
      |> assign(:workspaces, [])
      |> assign(:board, Snapshot.empty(now))
      |> assign(:scheduler_running, false)
      |> assign(:board_loaded?, false)
      |> assign(:board_error, nil)
      |> assign(:board_loading?, false)
      |> assign(:board_stale?, false)

    {:ok, if(live?, do: refresh_board(socket), else: socket)}
  end

  # ---- live updates ---------------------------------------------------------

  @impl true
  def handle_info({:task_lifecycle, _event, _issue}, socket),
    do: {:noreply, refresh_board(socket)}

  def handle_info({:worker_lifecycle, _event, _snapshot}, socket),
    do: {:noreply, refresh_board(socket)}

  def handle_info({:board_dispatched, _task_id}, socket),
    do: {:noreply, refresh_board(socket)}

  def handle_info({:board_scheduler, _state}, socket),
    do: {:noreply, refresh_board(socket)}

  def handle_info(:tick, socket), do: {:noreply, assign(socket, :now, DateTime.utc_now())}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:board, {:ok, loaded}, socket) do
    socket
    |> assign(:board, loaded.board)
    |> assign(:scheduler_running, loaded.scheduler_running)
    |> assign(:workspaces, loaded.workspaces)
    |> assign(:now, loaded.board.now)
    |> assign(:board_loaded?, true)
    |> assign(:board_error, nil)
    |> board_read_done()
  end

  # A read that fails must not take the page down, and must not pass itself
  # off as an empty fleet either. Whatever board is on screen stays there —
  # the skeleton on a first load, the last good read on a refresh — under an
  # error that says so.
  def handle_async(:board, {:exit, reason}, socket) do
    socket
    |> assign(:board_error, load_error(reason))
    |> board_read_done()
  end

  # ---- toolbar --------------------------------------------------------------

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket),
    do: {:noreply, assign(socket, :filter, filter)}

  def handle_event("retry_board", _params, socket),
    do: {:noreply, socket |> assign(:board_error, nil) |> refresh_board()}

  def handle_event("workspace", %{"workspace" => id}, socket),
    do: {:noreply, assign(socket, :workspace, id)}

  def handle_event("expand", %{"column" => key}, socket),
    do: {:noreply, assign(socket, :expanded, MapSet.put(socket.assigns.expanded, key))}

  # ---- refine (bd-1lszsc) ---------------------------------------------------

  # A Backlog card's Refine chip. The board holds snapshot cards rather than
  # issues, so the click carries the id and `ArbiterWeb.RefineEntry` — the same
  # module the issue detail page's button goes through — resolves it.
  def handle_event("refine", %{"id" => id}, socket),
    do: {:noreply, ArbiterWeb.RefineEntry.open(socket, id)}

  def handle_event("return_to_backlog", %{"id" => id}, socket) do
    case Ash.get(Issue, id) do
      {:ok, task} ->
        case Ash.update(task, %{}, action: :return_to_backlog) do
          {:ok, _demoted} ->
            {:noreply,
             socket
             |> put_flash(:info, "Returned to Backlog for further refinement.")
             |> refresh_board()}

          {:error, err} ->
            {:noreply, put_flash(socket, :error, ArbiterWeb.TaskForm.error_message(err))}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # ---- the scheduler switch -------------------------------------------------

  # One switch for the whole install, because there is one scheduler. Pausing
  # leaves in-flight work alone — it only stops the queue draining.
  def handle_event("toggle_scheduler", _params, socket) do
    if scheduler_running?() do
      case toggle_scheduler() do
        :ok ->
          {:noreply, refresh_board(socket)}

        {:error, _reason} ->
          {:noreply,
           put_flash(socket, :error, "The board scheduler didn't answer — try that again.")}
      end
    else
      {:noreply, put_flash(socket, :error, "The board scheduler isn't running on this install.")}
    end
  end

  # ---- drag: reordering Ready ----------------------------------------------

  # bd-asxw4e: the Ready queue is in the scheduler's own order — priority,
  # then the persisted rank — so a session-only hand-ranking would only make
  # the board promise an order Autopilot does not follow. Drag-to-rank, which
  # writes the rank, is bd-79w1fs; until then the gesture explains itself.
  def handle_event("reorder_ready", _params, socket) do
    {:noreply,
     socket
     |> put_flash(
       :info,
       "Ready is in priority order, then rank — the order the scheduler dispatches in. " <>
         "Change a card's priority to move it; drag-to-rank is coming."
     )
     |> refresh_board()}
  end

  # ---- drag: one gesture, and what each landing means -----------------------

  # The client reports the whole gesture — this card, out of that column, into
  # this one — and the board decides what it means. Most landings mean
  # nothing; the ones that do are enumerated here, in the order a person
  # would read them.
  def handle_event("drag", %{"id" => id, "from" => from, "to" => to}, socket)
      when is_binary(id) and is_binary(from) and is_binary(to) do
    {:noreply, dropped(socket, id, from, to)}
  end

  def handle_event("drag", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_stop", _params, socket),
    do: {:noreply, assign(socket, :confirm_stop, nil)}

  def handle_event("confirm_stop", _params, %{assigns: %{confirm_stop: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_stop", _params, socket) do
    id = socket.assigns.confirm_stop

    socket =
      case stop_worker_now(id) do
        :ok ->
          put_flash(socket, :info, "Stopped the worker on #{id}.")

        {:error, :not_found} ->
          put_flash(socket, :error, "No worker registered for #{id}.")

        {:error, reason} ->
          put_flash(socket, :error, "Could not stop the worker on #{id}: #{inspect(reason)}")
      end

    {:noreply, socket |> assign(:confirm_stop, nil) |> refresh_board()}
  end

  # ---- what a landing means ------------------------------------------------

  # A card released over the column it started in did nothing, whatever column
  # that is. This has to come first: without it a Running card picked up and
  # put straight back down falls through to the stop-the-worker prompt below,
  # which is one stray click from destroying live work the operator never
  # meant to touch.
  defp dropped(socket, _id, same, same), do: socket

  # Running is not a drop target. The whole point of the scheduler is that a
  # person does not decide *when* — so say what the card is waiting for
  # instead of pretending the drag did something.
  defp dropped(socket, id, _from, "running") do
    put_flash(
      socket,
      :error,
      "Running is the scheduler's column — #{id} goes in when a slot frees up and nothing " <>
        "blocks it. Its card says what it is waiting for."
    )
  end

  # Pulling a card out of Running kills a live agent mid-thought and throws
  # away whatever it had not yet written down, so the drag opens a question
  # rather than doing it.
  defp dropped(socket, id, "running", _to), do: assign(socket, :confirm_stop, id)

  # bd-9so315: a merged-but-unverified card has no gesture-shaped exit. Both
  # ways out of the state carry *evidence* — what was seen on the running
  # server — and a drag carries none, so neither drop may guess. Say what to
  # run instead, and leave the task where it is.
  defp dropped(socket, id, "waiting", to) when to in ["ready", "closed"] do
    if waiting_status(socket, id) == :awaiting_verification do
      put_flash(
        socket,
        :error,
        "#{id} merged but is awaiting verification — restart the server, observe the " <>
          "new path, then record what you saw: " <>
          ~s(`arb issue verify #{id} --observed "<evidence>"` ) <>
          "(or `--failed \"<evidence>\"` to send it back)."
      )
    else
      dropped_waiting(socket, id, to)
    end
  end

  # Everything else — a card dropped back where it came from, or onto a column
  # that implies no action. Silence is the right answer; a flash for every
  # stray drop trains the operator to ignore flashes.
  defp dropped(socket, _id, _from, _to), do: socket

  # Send back. The parked worker is halted already, so nothing is interrupted
  # — it is discarded, and the issue goes back to open so the queue owns it
  # again. Deliberately not `Dispatch.resume/1`: sending work back to Ready
  # means the scheduler re-decides it on the merits, not that a stale session
  # picks up where it left off.
  defp dropped_waiting(socket, id, "ready"), do: requeue(socket, id, "Sent")

  # Forward, out of Waiting. One gesture, two meanings, because the column
  # holds two kinds of card and the card — not the drop target — says which:
  # a *parked* worker is being told "carry on", a Merging ticket is being
  # pulled out of the merge queue.
  defp dropped_waiting(socket, id, "closed") do
    case waiting_status(socket, id) do
      :merging -> pull_from_merge(socket, id)
      _ -> proceed(socket, id)
    end
  end

  # Proceed. The answer the worker was parked on is "carry on", so un-park it
  # and let it finish its own way to review and a merge request. The FSM, not
  # the board, decides whether that is legal from where the card actually sits
  # — a review rejection parks at :failed and refuses.
  #
  # bd-92mx1m / bd-asxw4e: a ticket still In progress holds its own slot, so
  # un-parking it is never a new admission. One whose ticket has left In
  # progress meanwhile must acquire a slot — at a full cap it stays parked and
  # the flash names the cap and what holds it. No override here: going over the
  # cap is `arb worker resume --force` / MCP `force: true`, which is recorded.
  defp proceed(socket, id) do
    case proceed_slot(id) do
      :ok -> do_proceed(socket, id)
      {:error, message} -> put_flash(socket, :error, "#{id} could not proceed: #{message}")
    end
  end

  # Only a worker the FSM would actually un-park (`:waiting` on a question) is
  # gated: any other run state gets `Worker.resume/1`'s own, more useful,
  # refusal.
  defp proceed_slot(id) do
    with %{state: :waiting, waiting_on: :question} <- Worker.state(id),
         {:ok, %Issue{} = task} <- Ash.get(Issue, id),
         {:error, {:slot_cap_full, info}} <- ResumeSlot.admit(task, origin: :human) do
      {:error, ResumeSlot.refusal_message(info)}
    else
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp do_proceed(socket, id) do
    case Worker.resume(id) do
      :ok ->
        socket
        |> put_flash(:info, "#{id} may proceed — the worker picked up where it parked.")
        |> refresh_board()

      {:error, {:invalid_transition, run_state, _}} ->
        put_flash(
          socket,
          :error,
          "#{id} is #{run_state} — there is nothing parked to let proceed. Decide it on the " <>
            "task instead."
        )

      {:error, reason} ->
        put_flash(socket, :error, "#{id} could not proceed: #{inspect(reason)}")
    end
  end

  # Off the merge request. The merge request itself is not touched — what
  # stops is what would merge it — so this is reversible by restarting its
  # watchdog from the worker page.
  # bd-741sid: no worker is resident on an open PR — the ticket's Watchdog is
  # what keeps it in the merge queue. The pull stops it and is recorded on the
  # ticket, so no automatic restart undoes it (`PullRequest.pull/1`).
  defp pull_from_merge(socket, id) do
    case PullRequest.pull(id) do
      :ok ->
        put_flash(
          socket,
          :info,
          "Pulled #{id} out of the merge queue. Its merge request is untouched."
        )

      {:error, reason} ->
        put_flash(socket, :error, "#{id} could not be pulled out: #{inspect(reason)}")
    end
    |> refresh_board()
  end

  # Which half of Waiting the card is in, read off the board that rendered the
  # card the operator actually dragged.
  defp waiting_status(socket, id) do
    case Enum.find(socket.assigns.board.waiting, &(&1.id == id)) do
      nil -> nil
      card -> card.status
    end
  end

  # Stop whatever worker holds the card and hand the issue back to the queue.
  defp requeue(socket, id, verb) do
    socket
    |> stop_worker(id)
    |> reopen(id)
    |> put_flash(:info, "#{verb} #{id} back to the queue — the scheduler decides it from there.")
    |> refresh_board()
  end

  defp stop_worker(socket, id) do
    _ = stop_worker_now(id)
    socket
  end

  # `Worker.stop/3` defaults to `:infinity`, and `GenServer.stop/3` *exits the
  # caller* when the worker is already gone (a `:noproc` race against
  # `whereis/1`) or dies for a reason other than the one asked for. Neither is
  # survivable here: this runs in the LiveView, which is the operator's only
  # view of the fleet, so a worker wedged in `terminate/2` must not be able to
  # take the board down with it or hang it forever.
  defp stop_worker_now(id) do
    Worker.stop(id, :normal, @stop_timeout_ms)
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Back to `:open` so `Snapshot` counts it as Ready again. A worker leaves its
  # task `:in_progress` on purpose (so a failure stays inspectable), which is
  # exactly the state that would otherwise strand the card in no column at all.
  defp reopen(socket, id) do
    with {:ok, issue} <- Ash.get(Issue, id),
         true <- issue.status != :open,
         {:ok, _} <- Ash.update(issue, %{status: :open}) do
      socket
    else
      _ -> socket
    end
  end

  # ---- reads ----------------------------------------------------------------

  # The board the *scheduler* sees, so the reasons on screen are the reasons it
  # is acting on — but derived by this LiveView, not fetched from the
  # autopilot. The only thing that process contributes to a board read is the
  # pause flag, and asking it for the whole snapshot would put every open
  # board behind one mailbox: behind each other, and behind whatever the
  # autopilot is doing. Dispatch broadcasts `:started` mid-flight, so the
  # boards refreshing on that would be queueing against the very promotion
  # they are refreshing to show.
  #
  # When the autopilot isn't running at all there is nothing to drain the
  # queue, which is exactly what `paused: true` renders.
  #
  # Every read runs in `start_async/3` (bd-15bn6s): a snapshot is 280–400ms of
  # SQL, and this process has to go on answering clicks, ticks and broadcasts
  # meanwhile. At most one read is out at a time. Whatever asks for a refresh
  # while one is out marks the board stale, and the stale board gets exactly
  # one more read when the current one lands — so a burst of lifecycle
  # broadcasts costs two reads, not one each, and the second read sees
  # everything the burst changed.
  defp refresh_board(%{assigns: %{board_loading?: true}} = socket),
    do: assign(socket, :board_stale?, true)

  defp refresh_board(socket) do
    socket
    |> assign(:board_loading?, true)
    |> assign(:board_stale?, false)
    |> start_async(:board, fn -> load_board() end)
  end

  defp board_read_done(socket) do
    socket = assign(socket, :board_loading?, false)

    {:noreply, if(socket.assigns.board_stale?, do: refresh_board(socket), else: socket)}
  end

  # Runs in the async task. A raise or exit in here is the task's, and comes
  # back to `handle_async/3` as `{:exit, reason}`.
  #
  # The task is linked to this view, so a tab closed mid-read would kill it
  # mid-query — and a DB client that dies holding a checkout costs the pool
  # that connection (under test, the one shared sandbox connection,
  # bd-5scl0c). Trapping turns the view's exit into a message: the query in
  # flight finishes, and the task goes before it starts another.
  defp load_board do
    Process.flag(:trap_exit, true)
    running? = scheduler_running?()
    paused? = not running? or scheduler_paused?()

    board = Snapshot.load(now: DateTime.utc_now(), paused: paused?)
    exit_if_view_gone()
    workspaces = load_workspaces()
    exit_if_view_gone()

    %{board: board, scheduler_running: running?, workspaces: workspaces}
  end

  defp exit_if_view_gone do
    receive do
      {:EXIT, _view, _reason} -> exit(:shutdown)
    after
      0 -> :ok
    end
  end

  defp load_error({%{__exception__: true} = error, _stacktrace}), do: Exception.message(error)
  defp load_error(reason), do: Exception.format_exit(reason)

  defp scheduler_running? do
    Autopilot.running?(Autopilot)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # Bounded and exit-safe for the same reason the read is: the switch is on the
  # board, and a scheduler that has just died or is slow to answer must leave
  # the operator with a board and a flash, not a dead LiveView.
  defp toggle_scheduler do
    if scheduler_paused?(),
      do: Autopilot.resume(Autopilot, "dashboard"),
      else: Autopilot.pause(Autopilot, "dashboard")
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # A short budget and a caught exit, because this is on the render path: a
  # scheduler that cannot answer promptly is treated as one that is not
  # draining the queue, which is the reading that under-promises.
  defp scheduler_paused? do
    Autopilot.paused?(Autopilot, @scheduler_call_timeout_ms)
  rescue
    _ -> true
  catch
    :exit, _ -> true
  end

  # The workspace picker rides along with every board read, so a workspace
  # added since the page opened shows up in it. Its failure is not the
  # board's: an empty picker still leaves "all workspaces".
  defp load_workspaces do
    Arbiter.Tasks.Workspace |> Ash.read!() |> Enum.sort_by(& &1.name)
  rescue
    _ -> []
  end

  # ---- view-level filtering -------------------------------------------------
  #
  # The filter narrows what is *shown*; it never narrows what the scheduler
  # considers. Typing in a search box must not change which card gets
  # dispatched next.

  defp visible(assigns, cards, _key) do
    Enum.filter(cards, &matches?(&1, assigns))
  end

  defp matches?(card, assigns) do
    card = card_of(card)

    matches_workspace?(card, assigns.workspace) and matches_filter?(card, assigns.filter)
  end

  # A Ready entry wraps its card; every other column is the card itself.
  defp card_of(%{card: %{} = card}), do: card
  defp card_of(card), do: card

  defp matches_workspace?(_card, "all"), do: true
  defp matches_workspace?(card, id), do: Map.get(card, :workspace_id) == id

  defp matches_filter?(_card, filter) when filter in [nil, ""], do: true

  defp matches_filter?(card, filter) do
    needle = String.downcase(String.trim(filter))

    haystack =
      [Map.get(card, :id), Map.get(card, :title)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    needle == "" or String.contains?(haystack, needle)
  end

  # ---- card routing ---------------------------------------------------------

  # The card body/title, every column: always the issue's own page. A
  # `loop-` id is a loop run, not an issue, so it has no task page.
  defp task_navigate_href(card) do
    if String.starts_with?(to_string(card.id), "loop-"),
      do: ~p"/loop",
      else: ~p"/tasks/#{card.id}"
  end

  # Waiting's contextual destination — reachable via the action chip, not the
  # card body. A card sitting on a merge request is a merge-queue row;
  # anything else in Waiting is a worker you open and answer.
  #
  # bd-8jixav: unless its Watchdog is gone. The merge queue can do nothing
  # about a dead Watchdog — the restart lives on the worker page, so send the
  # operator there instead of to a screen that will only repeat the lie that
  # the MR is being polled.
  defp waiting_action_href(%{status: :awaiting_verification} = card), do: ~p"/tasks/#{card.id}"
  defp waiting_action_href(%{merge_pulled: true} = card), do: ~p"/workers/#{card.id}"
  defp waiting_action_href(%{watchdog_alive: false} = card), do: ~p"/workers/#{card.id}"
  defp waiting_action_href(%{status: :merging}), do: ~p"/merge_queue"
  defp waiting_action_href(card), do: ~p"/workers/#{card.id}"

  # ---- formatting -----------------------------------------------------------

  # bd-aw2cyt: how many agents are actually burning quota. `agents_live` is
  # what `Snapshot.derive/1` counted; an older board map (a stubbed snapshot in
  # a test, a replayed payload) falls back to the number of running cards,
  # which is what the header used to say.
  defp agents_live(board),
    do: Map.get(board, :agents_live) || length(Map.get(board, :running, []))

  # bd-45pwo1: what the dispatch cap actually measures — one per task not
  # yet done or parked for a human, not one per live agent. Differs from
  # `agents_live/1` whenever a task sits between rounds or waits on CI/merge
  # with no agent live for it right now; an older board map without the key
  # falls back to `slots_total - slots_free`, which is what `slots_free` was
  # already computed from.
  defp slots_used(board) do
    Map.get(board, :slots_used) ||
      max(Map.get(board, :slots_total, 0) - Map.get(board, :slots_free, 0), 0)
  end

  # The card's own line under the title: the phase it is in, which is what an
  # operator wants once the main agent has exited, falling back to the
  # workflow step for a card that has no phase (an older snapshot).
  defp card_footer(%{phase: phase}) when not is_nil(phase),
    do: Arbiter.Worker.Phase.label(phase)

  defp card_footer(card), do: Map.get(card, :step) && to_string(Map.get(card, :step))

  defp elapsed(nil, _now), do: nil

  defp elapsed(%DateTime{} = since, %DateTime{} = now) do
    secs = max(DateTime.diff(now, since, :second), 0)

    cond do
      secs < 60 -> "#{secs}s"
      secs < 3600 -> "#{div(secs, 60)}m"
      secs < 86_400 -> "#{div(secs, 3600)}h #{rem(div(secs, 60), 60)}m"
      true -> "#{div(secs, 86_400)}d"
    end
  end

  defp elapsed(_, _), do: nil

  defp clock(%DateTime{} = ts), do: Calendar.strftime(ts, "%H:%M")
  defp clock(_), do: ""

  defp relative(%DateTime{} = ts, %DateTime{} = now), do: "#{elapsed(ts, now)} ago"
  defp relative(_, _), do: ""

  # bd-8j9i9p (design bd-9jj5lf §3): worker spend past the p90 of what issues
  # like this one cost. A flag, not a hue — the card's accent belongs to the
  # state that owns it right now, and money is a second axis, so this reads
  # alongside `needs_you` rather than competing with it. Open cards only:
  # `Snapshot.derive/1` never sets it on a closed one.
  defp over_budget_flag(assigns) do
    ~H"""
    <span
      data-over-budget
      title="worker spend is past the p90 of what issues like this cost — excludes coordinator session overhead"
      aria-label="over budget"
      class="hero-banknotes"
      style="width: 11px; height: 11px; background-color: var(--arb-fail);"
    />
    """
  end

  defp quota_note(:ok), do: nil
  defp quota_note(nil), do: nil
  defp quota_note({:hold, reason}), do: reason
  defp quota_note(_), do: nil

  defp board_state(_loaded?, error) when is_binary(error), do: "error"
  defp board_state(true, nil), do: "loaded"
  defp board_state(false, nil), do: "loading"

  # A few placeholder cards per skeleton column, uneven so it reads as a
  # board rather than a grid.
  defp skeleton_cards("backlog"), do: ["h-[62px]", "h-[62px]"]
  defp skeleton_cards("ready"), do: ["h-[74px]", "h-[74px]", "h-[74px]"]
  defp skeleton_cards("running"), do: ["h-[92px]", "h-[92px]"]
  defp skeleton_cards("waiting"), do: ["h-[74px]"]
  defp skeleton_cards(_), do: ["h-[62px]", "h-[62px]", "h-[62px]"]

  defp scheduler_label(%{paused: true}), do: "paused"
  defp scheduler_label(_), do: "auto"

  # The one column head that carries a hue is the one whose state is the
  # operator's problem.
  defp head_hue("live"), do: "var(--arb-live)"
  defp head_hue("attention"), do: "var(--arb-attention)"
  defp head_hue(_), do: nil

  # ---- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:backlog, visible(assigns, assigns.board.backlog, "backlog"))
      |> assign(:ready, visible(assigns, assigns.board.ready, "ready"))
      |> assign(:running, visible(assigns, assigns.board.running, "running"))
      |> assign(:waiting, visible(assigns, assigns.board.waiting, "waiting"))
      |> assign(:closed, visible(assigns, assigns.board.closed_today, "closed"))

    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      quotas={@quotas}
      live={@live}
      coordinator_inbox={@coordinator_inbox}
      coordinator_outstanding_count={@coordinator_outstanding_count}
      coordinator_inbox_now={@coordinator_inbox_now}
    >
      <div class="px-4 py-4 flex flex-col gap-4">
        <div
          id="board"
          class="border border-solid border-[var(--border-default)] rounded-[var(--radius-panel)] overflow-hidden bg-[var(--surface-page)]"
          data-state={board_state(@board_loaded?, @board_error)}
          aria-busy={to_string(not @board_loaded? and is_nil(@board_error))}
        >
          <%!-- ── Toolbar ─────────────────────────────────────────────── --%>
          <div class="flex flex-wrap items-center gap-3 py-2 px-4 border-b border-solid border-[var(--border-default)] bg-[var(--arb-canvas-sunken)]">
            <form
              id="board-workspace-form"
              phx-change="workspace"
              class="flex-none min-w-[120px] max-w-xs"
            >
              <ArbiterWeb.CoreComponents.Forms.select
                name="workspace"
                size="sm"
                value={@workspace}
                options={[{"all workspaces", "all"} | Enum.map(@workspaces, &{&1.name, &1.id})]}
              />
            </form>

            <form id="board-filter-form" phx-change="filter" class="flex-none min-w-[180px] max-w-sm">
              <ArbiterWeb.CoreComponents.Forms.input
                name="filter"
                size="sm"
                mono={false}
                value={@filter}
                placeholder={"Filter #{plural(@issue_label)}"}
                key_hint="/"
                phx-debounce="150"
                icon={search_icon()}
              />
            </form>

            <span class="ml-auto flex flex-wrap items-center gap-2.5">
              <span
                :if={@board_loaded?}
                id="board-slots"
                class="hidden sm:inline text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
              >
                agents live: {agents_live(@board)} · slots used: {slots_used(@board)} of {@board.slots_total} · {@board.slots_free} slots free
              </span>
              <span
                :if={not @board_loaded?}
                aria-hidden="true"
                class="hidden sm:inline-block w-[260px] h-[6px] rounded-[var(--radius-pill)] bg-[var(--border-default)] animate-pulse"
              >
              </span>

              <%!-- Until the first read lands there is no scheduler state to
                   show, and a "paused" guess would be a claim. --%>
              <button
                :if={@board_loaded?}
                id="board-scheduler-toggle"
                type="button"
                phx-click="toggle_scheduler"
                title={
                  if @board.paused,
                    do: "The queue is not draining. Resume to let the scheduler dispatch.",
                    else: "The scheduler is promoting Ready cards as slots free up."
                }
                class={[
                  "cursor-pointer px-2 py-[3px] rounded-[var(--radius-chip)] border border-solid",
                  "text-[10px] font-medium font-[family-name:var(--font-mono)] uppercase tracking-[0.08em]",
                  if(@board.paused,
                    do:
                      "border-[color-mix(in_oklch,var(--arb-attention)_45%,transparent)] text-[var(--arb-attention)]",
                    else:
                      "border-[color-mix(in_oklch,var(--arb-live)_45%,transparent)] text-[var(--arb-live)]"
                  )
                ]}
              >
                scheduler {scheduler_label(@board)}
              </button>

              <ArbiterWeb.CoreComponents.Core.button
                variant="primary"
                size="sm"
                key_hint="C"
                phx-click={JS.navigate(~p"/tasks")}
              >
                New {@issue_label}
              </ArbiterWeb.CoreComponents.Core.button>
            </span>
          </div>

          <%!-- ── Load error ──────────────────────────────────────────
               A failed read, first or refresh. Whatever board was on
               screen stays under it (bd-15bn6s). --%>
          <div
            :if={@board_error}
            id="board-error"
            role="alert"
            class="flex items-start gap-2 px-4 py-2.5 border-b border-solid border-[var(--arb-fail-edge)] bg-[var(--arb-fail-wash)] text-[12px] text-[var(--arb-fail-text)]"
          >
            <.icon name="hero-exclamation-triangle-micro" class="size-4 shrink-0 mt-px" />
            <span class="grow min-w-0 break-words">
              Could not load the board: {@board_error}<span :if={@board_loaded?}>
                — showing the last board that loaded.</span>
            </span>
            <button
              type="button"
              id="board-retry"
              phx-click="retry_board"
              class={[
                "shrink-0 px-2 h-[22px] rounded-[var(--radius-field)] cursor-pointer",
                "border border-solid border-[var(--arb-fail-edge)] bg-[var(--surface-chrome)]",
                "text-[11px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] transition-colors"
              ]}
            >
              Retry
            </button>
          </div>

          <%!-- ── Skeleton ────────────────────────────────────────────
               The first read is out: the five columns, with nothing claimed
               about what is in them. --%>
          <div
            :if={not @board_loaded? and is_nil(@board_error)}
            id="board-loading"
            aria-label="Loading the board"
            class="flex overflow-x-auto snap-x snap-mandatory gap-px bg-[var(--arb-line-soft)] min-h-[560px] xl:grid xl:grid-cols-5"
          >
            <div
              :for={column <- @columns}
              id={"board-loading-#{column.key}"}
              class="flex-shrink-0 w-[85vw] md:w-72 snap-start bg-[var(--surface-page)] px-3 pt-3 pb-4 flex flex-col gap-[9px] xl:w-auto"
            >
              <.column_head label={column.label} count="·" tone={column.tone} />
              <div
                :for={height <- skeleton_cards(column.key)}
                aria-hidden="true"
                class={[
                  "rounded-[var(--radius-field)] border border-solid border-[var(--arb-line-soft)]",
                  "bg-[var(--surface-card)] px-[11px] py-[10px] flex flex-col gap-2 animate-pulse",
                  height
                ]}
              >
                <span class="w-3/4 h-[6px] rounded-[var(--radius-pill)] bg-[var(--border-default)]">
                </span>
                <span class="w-1/2 h-[6px] rounded-[var(--radius-pill)] bg-[var(--border-default)]">
                </span>
              </div>
            </div>
          </div>

          <%!-- ── Columns ─────────────────────────────────────────────── --%>
          <div
            :if={@board_loaded?}
            id="board-columns"
            phx-hook=".BoardDrag"
            class="flex overflow-x-auto snap-x snap-mandatory gap-px bg-[var(--arb-line-soft)] min-h-[560px] xl:grid xl:grid-cols-5"
          >
            <%!-- Backlog — written down, not yet thought through. No reason
                 line, no accent, no drag: nothing here is queued for anything,
                 and the only way out is the detail page's promote button. --%>
            <div
              id="board-column-backlog"
              data-column="backlog"
              class="flex-shrink-0 w-[85vw] md:w-72 snap-start bg-[var(--surface-page)] px-3 pt-3 pb-4 flex flex-col gap-[9px] xl:w-auto"
            >
              <.column_head label="Backlog" count={length(@backlog)} tone={nil} />

              <div
                :for={card <- Enum.take(@backlog, limit(@expanded, "backlog"))}
                id={"card-#{card.id}"}
                class="contents"
                phx-click={JS.navigate(task_navigate_href(card))}
              >
                <.task_card
                  id={card.id}
                  title={card.title || card.id}
                  priority={card.priority}
                  type={card.issue_type}
                  difficulty={card.difficulty}
                  footer={relative(card.created_at, @now)}
                  class="cursor-pointer"
                  data-card={card.id}
                  data-column="backlog"
                >
                  <:parent :if={card.parent}>
                    <.parent_link parent={card.parent} mode="compact" />
                  </:parent>
                  <:status :if={card.over_budget}>
                    <.over_budget_flag />
                  </:status>
                  <%!-- Refine (bd-1lszsc). Every card in this column is, by
                       construction, exactly what `Refine.eligible?/1` accepts —
                       `Board.Snapshot` builds Backlog from queueable, unrefined
                       issues — so there is nothing to gate on here. Nesting it
                       inside the card's own `phx-click` navigation is safe:
                       LiveView resolves a click to the *nearest* `phx-click`
                       ancestor, so this button's event fires and the card's
                       navigate does not. --%>
                  <:actions>
                    <ArbiterWeb.RefineEntry.refine_button
                      id={"board-refine-#{card.id}"}
                      issue_id={card.id}
                      variant="ghost"
                    />
                  </:actions>
                </.task_card>
              </div>

              <.more
                :if={length(@backlog) > limit(@expanded, "backlog")}
                column="backlog"
                count={length(@backlog) - limit(@expanded, "backlog")}
              />

              <div
                :if={@backlog == []}
                id="board-backlog-empty"
                class="mt-auto px-2 py-2 text-center rounded-[var(--radius-field)] border border-dashed border-[var(--border-strong)] text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
              >
                nothing waiting to be refined
              </div>
            </div>

            <%!-- Ready — the queue. Every card says why it is or isn't going. --%>
            <div
              id="board-column-ready"
              data-column="ready"
              class="flex-shrink-0 w-[85vw] md:w-72 snap-start bg-[var(--surface-page)] px-3 pt-3 pb-4 flex flex-col gap-[9px] xl:w-auto"
            >
              <.column_head label="Ready" count={length(@ready)} tone={nil} />

              <div
                :for={entry <- Enum.take(@ready, limit(@expanded, "ready"))}
                id={"card-#{entry.card.id}"}
                class="contents"
                phx-click={JS.navigate(task_navigate_href(entry.card))}
              >
                <.task_card
                  id={entry.card.id}
                  title={entry.card.title || entry.card.id}
                  priority={entry.card.priority}
                  type={entry.card.issue_type}
                  difficulty={entry.card.difficulty}
                  activity={entry.reason}
                  accent={ready_accent(entry.state)}
                  draggable="true"
                  class="cursor-pointer"
                  data-card={entry.card.id}
                  data-column="ready"
                >
                  <:parent :if={entry.card.parent}>
                    <.parent_link parent={entry.card.parent} mode="compact" />
                  </:parent>
                  <:status :if={entry.card.over_budget}>
                    <.over_budget_flag />
                  </:status>
                  <:actions>
                    <ArbiterWeb.DemoteEntry.demote_button
                      :if={ArbiterWeb.DemoteEntry.eligible?(entry.card)}
                      id={"board-demote-#{entry.card.id}"}
                      issue_id={entry.card.id}
                      variant="ghost"
                    />
                  </:actions>
                </.task_card>
              </div>

              <.more
                :if={length(@ready) > limit(@expanded, "ready")}
                column="ready"
                count={length(@ready) - limit(@expanded, "ready")}
              />

              <%!-- Where the handoff put "drop to dispatch". The queue drains
                   itself, so what belongs here is the reason it might not. --%>
              <div
                id="board-ready-foot"
                class="mt-auto px-2 py-2 text-center rounded-[var(--radius-field)] border border-dashed border-[var(--border-strong)] text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
              >
                {ready_foot(@board, @scheduler_running)}
              </div>
            </div>

            <%!-- Running — the machine's column. Drag out, never in. --%>
            <div
              id="board-column-running"
              data-column="running"
              class="flex-shrink-0 w-[85vw] md:w-72 snap-start bg-[var(--surface-page)] px-3 pt-3 pb-4 flex flex-col gap-[9px] xl:w-auto"
            >
              <.column_head
                label="Running"
                count={"#{length(@running)} / #{@board.slots_total}"}
                tone="live"
              />

              <div
                :for={card <- Enum.take(@running, limit(@expanded, "running"))}
                id={"card-#{card.id}"}
                class="contents"
                phx-click={JS.navigate(task_navigate_href(card))}
              >
                <.task_card
                  id={card.id}
                  title={card.title || card.id}
                  accent="live"
                  activity={card.activity}
                  activity_href={~p"/workers/#{card.id}"}
                  difficulty={card.difficulty}
                  footer={card_footer(card)}
                  draggable="true"
                  class="cursor-pointer"
                  data-card={card.id}
                  data-column="running"
                >
                  <:parent :if={card.parent}>
                    <.parent_link parent={card.parent} mode="compact" />
                  </:parent>
                  <:status>
                    <span class="flex items-center gap-1.5">
                      <.over_budget_flag :if={card.over_budget} />
                      <.provider_icon
                        provider={card.provider}
                        class="size-3.5 text-[var(--text-label)]"
                      />
                      <%!-- bd-aw2cyt: the pulse is a claim that something is
                      running. Only a card with a live agent gets it; a card
                      whose agent has exited (in review, waiting on CI, between
                      rounds) goes quiet and says so. --%>
                      <span
                        data-phase={card.phase}
                        data-agent-live={to_string(card.agent_live)}
                        class={[
                          "text-[10px] font-medium font-[family-name:var(--font-mono)]",
                          if(card.agent_live,
                            do:
                              "text-[var(--arb-live)] animate-[arb-pulse_var(--pulse-period)_var(--ease-in-out)_infinite]",
                            else: "text-[var(--text-label)] opacity-70"
                          )
                        ]}
                      >
                        {elapsed(card.since, @now)}
                      </span>
                    </span>
                  </:status>
                </.task_card>
              </div>

              <.more
                :if={length(@running) > limit(@expanded, "running")}
                column="running"
                count={length(@running) - limit(@expanded, "running")}
              />
            </div>

            <%!-- Waiting — the worker is done; the outcome is somewhere else.
                 Uniform cards: the flag, not a hue, marks the ones that are
                 yours. The column head still takes the attention hue when it
                 holds any of them, because a board is read from across a
                 room before it is read card by card. --%>
            <div
              id="board-column-waiting"
              data-column="waiting"
              class="flex-shrink-0 w-[85vw] md:w-72 snap-start bg-[var(--surface-page)] px-3 pt-3 pb-4 flex flex-col gap-[9px] xl:w-auto"
            >
              <.column_head
                label="Waiting"
                count={length(@waiting)}
                tone={if Enum.any?(@waiting, & &1.needs_you), do: "attention", else: nil}
              />

              <div
                :for={card <- Enum.take(@waiting, limit(@expanded, "waiting"))}
                id={"card-#{card.id}"}
                class="contents"
                phx-click={JS.navigate(task_navigate_href(card))}
              >
                <.task_card
                  id={card.id}
                  title={card.title || card.id}
                  activity={waiting_activity(card)}
                  footer={waiting_note(card, waiting_activity(card))}
                  draggable="true"
                  class="cursor-pointer"
                  data-card={card.id}
                  data-column="waiting"
                >
                  <:parent :if={card.parent}>
                    <.parent_link parent={card.parent} mode="compact" />
                  </:parent>
                  <:status>
                    <span class="flex items-center gap-1.5">
                      <.over_budget_flag :if={card.over_budget} />
                      <span
                        :if={card.needs_you}
                        data-needs-you
                        title="needs you — only a person can move this"
                        aria-label="needs you"
                        class="hero-flag"
                        style="width: 11px; height: 11px; background-color: var(--arb-attention);"
                      />
                      <span class="text-[10px] font-medium font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                        {elapsed(card.since, @now)} waiting
                      </span>
                    </span>
                  </:status>
                  <:actions>
                    <.link navigate={waiting_action_href(card)} class="contents">
                      <span class="px-2 py-[2px] rounded-[var(--radius-chip)] text-[10px] font-medium font-[family-name:var(--font-mono)] border border-solid border-[var(--border-strong)] text-[var(--text-link)]">
                        {waiting_action(card)}
                      </span>
                    </.link>
                    <.link navigate={~p"/tasks/#{card.id}"} class="contents">
                      <span class="px-2 py-[2px] rounded-[var(--radius-chip)] text-[10px] font-medium font-[family-name:var(--font-mono)] border border-solid border-[var(--arb-done-edge)] text-[var(--text-secondary)]">
                        {@issue_label}
                      </span>
                    </.link>
                  </:actions>
                </.task_card>
              </div>

              <.more
                :if={length(@waiting) > limit(@expanded, "waiting")}
                column="waiting"
                count={length(@waiting) - limit(@expanded, "waiting")}
              />
            </div>

            <%!-- Closed in the last 24 hours (rolling). No action on it. --%>
            <div
              id="board-column-closed"
              data-column="closed"
              class="flex-shrink-0 w-[85vw] md:w-72 snap-start bg-[var(--surface-page)] px-3 pt-3 pb-4 flex flex-col gap-[9px] xl:w-auto"
            >
              <.column_head label="Closed · last 24h" count={length(@closed)} tone={nil} />

              <div
                :for={card <- Enum.take(@closed, limit(@expanded, "closed"))}
                id={"card-#{card.id}"}
                class="contents"
                phx-click={JS.navigate(task_navigate_href(card))}
              >
                <.task_card
                  id={card.id}
                  title={card.title || card.id}
                  muted
                  footer={"closed #{clock(card.closed_at)}"}
                  class="cursor-pointer"
                  data-card={card.id}
                  data-column="closed"
                >
                  <:parent :if={card.parent}>
                    <.parent_link parent={card.parent} mode="compact" />
                  </:parent>
                </.task_card>
              </div>

              <div
                :if={length(@closed) > limit(@expanded, "closed")}
                class="flex items-center justify-between px-[11px] py-[9px] rounded-[var(--radius-field)] border border-dashed border-[var(--arb-line)]"
              >
                <span class="text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                  {length(@closed) - limit(@expanded, "closed")} more
                </span>
                <.link
                  navigate={~p"/tasks"}
                  class="text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-link)]"
                >
                  →
                </.link>
              </div>
            </div>
          </div>
        </div>

        <%!-- ── Stop confirmation ───────────────────────────────────────
             Pulling a card out of Running kills a live agent. The drag opens
             this; only the button here stops anything. --%>
        <div
          :if={@confirm_stop}
          id="board-confirm-stop"
          class="flex items-center gap-3 px-4 py-3 rounded-[var(--radius-panel)] border border-solid border-[color-mix(in_oklch,var(--arb-fail)_45%,transparent)] bg-[var(--surface-card)]"
        >
          <span class="text-[12.5px] text-[var(--text-title)]">
            Stop the {@worker_label} on <code class="font-[family-name:var(--font-mono)]">{@confirm_stop}</code>? Its agent
            dies where it stands; the worktree and everything committed survive.
          </span>
          <span class="ml-auto flex items-center gap-2">
            <ArbiterWeb.CoreComponents.Core.button variant="ghost" size="sm" phx-click="cancel_stop">
              Cancel
            </ArbiterWeb.CoreComponents.Core.button>
            <ArbiterWeb.CoreComponents.Core.button variant="danger" size="sm" phx-click="confirm_stop">
              Stop {@worker_label}
            </ArbiterWeb.CoreComponents.Core.button>
          </span>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".BoardDrag">
        // Drag is a human action, and only for the moves a human decides:
        // reorder within Ready, pull out of Running, move a Waiting card back
        // to Ready or forward out of the column. Dropping INTO Running is pushed
        // to the server so it can explain itself rather than silently no-op.
        export default {
          mounted() { this.wire() },
          updated() { this.wire() },
          wire() {
            if (this.wired) return
            this.wired = true
            const el = this.el

            el.addEventListener("dragstart", (e) => {
              const card = e.target.closest("[data-card]")
              if (!card) return
              this.dragging = {id: card.dataset.card, from: card.dataset.column}
              e.dataTransfer.effectAllowed = "move"
              try { e.dataTransfer.setData("text/plain", card.dataset.card) } catch (_) {}
            })

            el.addEventListener("dragover", (e) => {
              if (this.dragging) e.preventDefault()
            })

            el.addEventListener("drop", (e) => {
              const drag = this.dragging
              this.dragging = null
              if (!drag) return
              e.preventDefault()

              const column = e.target.closest("[data-column]")
              if (!column) return
              const to = column.dataset.column

              // Reordering Ready is the one gesture the client resolves on
              // its own, because only it knows where the cursor landed.
              if (to === "ready" && drag.from === "ready") {
                const ids = Array.from(column.querySelectorAll("[data-card]"))
                  .map((n) => n.dataset.card)
                const over = e.target.closest("[data-card]")
                const rest = ids.filter((id) => id !== drag.id)
                const at = over && over.dataset.card !== drag.id
                  ? rest.indexOf(over.dataset.card)
                  : rest.length
                rest.splice(at < 0 ? rest.length : at, 0, drag.id)
                this.pushEvent("reorder_ready", {order: rest})
                return
              }

              // Everything else is reported as-is. What a landing means is
              // the server's call, including "nothing".
              this.pushEvent("drag", {id: drag.id, from: drag.from, to: to})
            })
          },
        }
      </script>
    </Layouts.app>
    """
  end

  # ---- render helpers -------------------------------------------------------

  attr(:label, :string, required: true)
  attr(:count, :any, required: true)
  attr(:tone, :any, default: nil)

  defp column_head(assigns) do
    assigns = assign(assigns, :hue, head_hue(assigns.tone))

    ~H"""
    <div
      class="flex items-center justify-between pb-[9px] mb-[9px] border-b border-solid"
      style={
        if(@hue,
          do: "border-color: color-mix(in oklch, #{@hue} 38%, transparent)",
          else: "border-color: var(--arb-line-soft)"
        )
      }
    >
      <span
        class="text-[10.5px] font-medium uppercase tracking-[0.1em] font-[family-name:var(--font-mono)]"
        style={"color: #{@hue || "var(--text-secondary)"}"}
      >
        {@label}
      </span>
      <span
        class="text-[10.5px] font-medium font-[family-name:var(--font-mono)]"
        style={"color: #{@hue || "var(--text-label)"}"}
      >
        {@count}
      </span>
    </div>
    """
  end

  attr(:column, :string, required: true)
  attr(:count, :integer, required: true)

  defp more(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="expand"
      phx-value-column={@column}
      class="flex items-center justify-between px-[11px] py-[9px] rounded-[var(--radius-field)] border border-dashed border-[var(--arb-line)]"
    >
      <span class="text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
        {@count} more
      </span>
      <span class="text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-link)]">
        show
      </span>
    </button>
    """
  end

  # `Forms.input`'s `icon` is interpolated, not rendered as a component, so it
  # takes finished markup. Same span `Core.icon/1` builds: the Heroicon class
  # plus an explicit box, masked to the label colour.
  defp search_icon do
    Phoenix.HTML.raw(
      ~s|<span aria-hidden="true" class="hero-magnifying-glass" | <>
        ~s|style="width: 11px; height: 11px; background-color: var(--text-label);"></span>|
    )
  end

  defp limit(expanded, column) do
    if MapSet.member?(expanded, column), do: 1_000, else: @column_limit
  end

  defp ready_accent(:next), do: "live"
  defp ready_accent(:blocked), do: "attention"
  defp ready_accent(_), do: nil

  # The one live line on a Waiting card: why the worker stopped, or — for one
  # already sitting on a merge request — which request.
  defp waiting_activity(%{status: :merging} = card), do: merge_activity(card)
  defp waiting_activity(%{reason: reason}) when is_binary(reason) and reason != "", do: reason
  defp waiting_activity(_card), do: "waiting"

  # The state word under the card. Deliberately the same mono grey for every
  # card in the column: what separates them is the flag, not the palette.
  # Suppressed when the activity line above it already says the same thing —
  # a worker that stopped with no summary reports "failed" for both.
  defp waiting_note(card, activity) do
    case waiting_note(card) do
      ^activity -> with_collapsed(nil, card)
      note -> with_collapsed(note, card)
    end
  end

  # bd-8jixav: one task is one card, but a collapsed subordinate row's failure
  # is not the primary row's to swallow — a dead fix pass under a parked
  # primary is exactly the invisibility this ticket is about.
  defp with_collapsed(note, %{collapsed_note: extra}) when is_binary(extra) and extra != "" do
    case note do
      nil -> extra
      note -> note <> " · " <> extra
    end
  end

  defp with_collapsed(note, _card), do: note

  # bd-8jixav: a Watchdog is a `:temporary` child — when it dies the ticket
  # stays Merging on a genuinely open MR that nothing polls, and every other
  # field on the card keeps reading like an ordinary review wait. This note is
  # the whole difference between "the machine is working on it" and "this will
  # sit here forever", so it outranks the merge status it replaces.
  #
  # bd-741sid: except when the operator pulled it out of the merge queue.
  # Then nothing polling it is the point, not an alarm.
  defp waiting_note(%{merge_pulled: true}), do: "pulled from merge queue"
  defp waiting_note(%{watchdog_alive: false}), do: "no watchdog polling"
  defp waiting_note(%{status: :merging} = card), do: merge_status_text(card.merger_status)
  defp waiting_note(%{status: :finished, outcome: :failed}), do: "failed"
  defp waiting_note(%{status: :in_progress}), do: "no live worker"
  defp waiting_note(%{status: :awaiting_verification}), do: "restart & observe"
  defp waiting_note(_card), do: "parked"

  defp waiting_action(%{merge_pulled: true}), do: "restart watchdog"
  defp waiting_action(%{watchdog_alive: false}), do: "restart watchdog"
  defp waiting_action(%{status: :merging}), do: "merge queue"
  defp waiting_action(%{status: :finished, outcome: :failed}), do: "retry"
  defp waiting_action(%{status: :in_progress}), do: "resume"
  defp waiting_action(%{status: :awaiting_verification}), do: "verify"
  defp waiting_action(_card), do: "answer"

  defp merge_activity(%{mr_ref: ref}) when is_binary(ref) and ref != "", do: ref
  defp merge_activity(_card), do: "waiting on checks"

  # `card.merger_status` is the raw poll result Arbiter.Worker.Watchdog reads
  # (a map with :status/:approved/:pipeline/etc, not a display string) — reduce
  # it the same way merge_queue_index_live.ex does, to the board's short
  # lowercase mono vocabulary instead of rendering the map itself.
  defp merge_status_text(nil), do: "checks"

  defp merge_status_text(status) when is_map(status) do
    case Watchdog.effective_block_reason(status) do
      nil ->
        case Watchdog.classify(status) do
          :merged -> "merged"
          :approved -> "approved"
          :closed -> "closed"
          :pending -> "checks"
        end

      reason ->
        block_reason_text(reason)
    end
  end

  defp merge_status_text(_status), do: "checks"

  defp block_reason_text(:conflict), do: "conflict"
  defp block_reason_text(:behind_base), do: "behind base"
  defp block_reason_text(:ci_failed), do: "ci failed"
  defp block_reason_text(:needs_approval), do: "needs approval"
  defp block_reason_text(:needs_nonauthor_approval), do: "awaiting reviewer"
  defp block_reason_text(:draft), do: "draft"
  defp block_reason_text(:blocked_other), do: "blocked"
  defp block_reason_text(other), do: "blocked · #{other}"

  # The foot of the Ready column, where the handoff's drop zone used to be.
  defp ready_foot(%{paused: true}, false),
    do: "scheduler not running — nothing is draining this queue"

  defp ready_foot(%{paused: true}, _), do: "scheduler paused — resume to dispatch"

  defp ready_foot(%{promote: id}, _) when is_binary(id), do: "dispatching #{id}..."

  defp ready_foot(board, _) do
    case quota_note(board.quota) do
      nil ->
        if board.slots_free > 0,
          do: "queue drains automatically",
          else: "no free worker slot"

      note ->
        note
    end
  end
end
