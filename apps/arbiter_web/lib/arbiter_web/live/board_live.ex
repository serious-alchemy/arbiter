defmodule ArbiterWeb.BoardLive do
  @moduledoc """
  The board — the home screen, and the only page that answers "what is the
  fleet doing" in one look.

  ## Seven columns, one per lifecycle column (bd-79w1fs)

  **Backlog, Blocked, Ready, In progress, Merging, Verifying, Closed · last
  24h** — `docs/design/ticket-lifecycle.md` §3. Every card is placed purely by
  its ticket's `Arbiter.Tasks.Lifecycle.view/2` column, which
  `Arbiter.Board.Snapshot` reads; nothing here is stored, so nothing here can
  drift. Epics stay off the board and reach it only as the `↳` chip a child
  card carries.

  Each card says what its column knows about it:

    * **Blocked** — `waiting on <ids>`, its unsatisfied gating blockers;
    * **Ready** — the scheduler's reason: `next up`, `N ahead in queue`, or a
      hold (slot, quota, paused, conflict, file overlap). A hold reads
      `held — …` here, because *blocked* is the column next door;
    * **In progress** and **Merging** — the computed `step`;
    * **Closed** — the `close_reason` (completed / won't do / duplicate).

  ## Attention is an overlay, not a column

  A ticket with attention keeps its column and wears a marker naming who has
  to act (operator or coordinator) and why. The **Needs-attention swimlane**
  across the top collects them: operator-owned items by default, a chip adds
  the coordinator's, and active system alerts (`Arbiter.Alerts`, bd-7gt8rm)
  appear as cards with no ticket. The lane collapses to a count. Whether it is
  open and whether the chip is on are a per-viewer convenience, so they live
  in the viewer's browser storage (the `.AttentionLane` hook), not on the
  server: the hook restores them on mount and stores each change the server
  pushes back. With no storage (private mode, a blocked `localStorage`) the
  lane simply starts open, operator-only.

  ## Manual order

  Backlog and Ready sort by priority, then the persisted `rank`
  (`Arbiter.Board.Scheduler.order/1`) — the order Autopilot dispatches Ready
  in, so the column is the queue. Dragging within either column rewrites
  `rank` through `Arbiter.Tasks.Rank.move/2` (the `:set_rank` action,
  bd-djapyj), placed next to the nearest card of the same workspace, since
  rank is per workspace. Dropping into a different priority band changes the
  ticket's priority to that band first.

  The bands are effective priority (ES6, `docs/design/epic-aware-scheduling.md`
  §6.3). A drag pins the card (`rank_pinned`) and the cards above it in its
  band, so it sorts first in the band ahead of the finish-first tiebreak; a
  drop into a band worse than the card's epic floor is refused with a flash.

  ## Column drags

  Backlog → Blocked or Ready is **promote** (the `:promote` transition, with
  its acceptance-criteria rule); Blocked or Ready → Backlog is **demote**.
  Where a promoted ticket lands — Blocked or Ready — is its dependencies'
  call, not the drop target's. Every other cross-column drag is refused with
  a flash: the rest of the lifecycle moves with the work (the scheduler
  dispatches, a PR opens, a merge lands), and a gesture cannot carry the
  evidence those moves need.

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
  alias Arbiter.Settings
  alias Arbiter.Tasks.EdgeGate
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Rank
  alias ArbiterWeb.InstallationSettings

  @tasks_topic "tasks"
  @workers_topic "workers"

  # How many cards a column shows before it collapses into an "N more" row.
  @column_limit 8

  @columns [
    %{key: "backlog", label: "Backlog", board_key: :backlog, tone: nil},
    %{key: "blocked", label: "Blocked", board_key: :blocked, tone: nil},
    %{key: "ready", label: "Ready", board_key: :ready, tone: nil},
    %{key: "in_progress", label: "In progress", board_key: :in_progress, tone: "live"},
    %{key: "merging", label: "Merging", board_key: :merging, tone: nil},
    %{key: "verifying", label: "Verifying", board_key: :verifying, tone: nil},
    %{key: "closed", label: "Closed · last 24h", board_key: :closed_today, tone: nil}
  ]

  @column_keys Enum.map(@columns, & &1.key)
  @rank_columns ["backlog", "ready"]
  @queued_columns ["blocked", "ready"]

  @step_labels %{
    implementing: "implementing",
    in_review: "in review",
    awaiting_ci: "waiting on CI",
    addressing_review: "addressing review",
    fixing_ci: "fixing CI",
    resolving_conflict: "resolving conflict",
    waiting_ci: "waiting on CI",
    in_merge_queue: "in merge queue",
    behind_base: "behind base",
    merge_blocked: "merge blocked"
  }

  @close_reason_labels %{completed: "completed", wont_do: "won't do", duplicate: "duplicate"}

  @impl true
  def mount(_params, _session, socket) do
    live? = connected?(socket)

    if live? do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @tasks_topic)
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @workers_topic)
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Autopilot.topic())
      # The concurrency cap is also editable on /settings, REST and the CLI.
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Settings.topic())
      # System alerts and attention changes are announced on the event stream
      # (`inbox` topic), not the tasks topic — the global copy carries every
      # workspace's, which is what an all-workspaces board wants.
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(nil))
      # Elapsed counters on In-progress cards. Reassigns `:now` only — no reads.
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
      |> assign(:columns, @columns)
      |> assign(:issue_label, "ticket")
      |> assign(:workspaces, [])
      |> assign(:board, Snapshot.empty(now))
      |> assign(:alerts, [])
      |> assign(:paused_providers, [])
      |> assign(:local_cap_zero?, false)
      |> assign(:lane_open, true)
      |> assign(:lane_coordinator, false)
      |> assign(:scheduler_running, false)
      |> assign(:system_cap, nil)
      |> assign(:system_cap_override?, false)
      |> assign(:board_loaded?, false)
      |> assign(:board_error, nil)
      |> assign(:board_loading?, false)
      |> assign(:board_stale?, false)
      |> assign(:worker_refresh_timer, nil)

    {:ok, if(live?, do: refresh_board(socket), else: socket)}
  end

  # ---- live updates ---------------------------------------------------------

  @impl true
  def handle_info({:task_lifecycle, _event, _issue}, socket),
    do: {:noreply, refresh_board(socket)}

  # bd-81vbzg: workers broadcast often and every tab refreshes on each one
  # (a ~280ms read). The first broadcast arms a trailing timer; the rest of
  # the burst rides on it, and the one refresh reads the final state.
  def handle_info({:worker_lifecycle, _event, _snapshot}, socket) do
    case {worker_debounce_ms(), socket.assigns.worker_refresh_timer} do
      {0, _} ->
        {:noreply, refresh_board(socket)}

      {_, timer} when not is_nil(timer) ->
        {:noreply, socket}

      {ms, nil} ->
        timer = Process.send_after(self(), :worker_refresh_due, ms)
        {:noreply, assign(socket, :worker_refresh_timer, timer)}
    end
  end

  def handle_info(:worker_refresh_due, socket),
    do: {:noreply, socket |> assign(:worker_refresh_timer, nil) |> refresh_board()}

  def handle_info({:board_dispatched, _task_id}, socket),
    do: {:noreply, refresh_board(socket)}

  def handle_info({:board_scheduler, _state}, socket),
    do: {:noreply, refresh_board(socket)}

  # The cap (or the watchdog) changed somewhere else — /settings, REST, the CLI.
  def handle_info({:installation_settings_changed, _field}, socket),
    do: {:noreply, refresh_board(socket)}

  # A system alert raised or cleared, or a ticket's attention raised, moved or
  # handed back: the swimlane's inputs.
  def handle_info({:event, %{topic: "inbox", kind: kind}}, socket)
      when kind in ["alert", "attention"],
      do: {:noreply, refresh_board(socket)}

  # bd-5ef587: a provider paused or resumed — the banner's input.
  def handle_info({:event, %{topic: topic}}, socket)
      when topic in ["provider_paused", "provider_resumed"],
      do: {:noreply, refresh_board(socket)}

  def handle_info(:tick, socket), do: {:noreply, assign(socket, :now, DateTime.utc_now())}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:board, {:ok, loaded}, socket) do
    socket
    |> assign(:board, loaded.board)
    |> assign(:alerts, loaded.alerts)
    |> assign(:paused_providers, loaded.paused_providers)
    |> assign(:local_cap_zero?, loaded.local_cap_zero?)
    |> assign(:scheduler_running, loaded.scheduler_running)
    |> assign(:system_cap, loaded.system_cap)
    |> assign(:system_cap_override?, loaded.system_cap_override?)
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

  # ---- the Needs-attention swimlane ------------------------------------------

  def handle_event("toggle_attention_lane", _params, socket),
    do: {:noreply, socket |> update(:lane_open, &(not &1)) |> push_lane_pref()}

  def handle_event("toggle_attention_coordinator", _params, socket),
    do: {:noreply, socket |> update(:lane_coordinator, &(not &1)) |> push_lane_pref()}

  # The `.AttentionLane` hook, on mount, with what the viewer's browser stored.
  # Anything that is not a boolean — nothing stored, storage unavailable, a
  # value from some other build — leaves that setting at its default.
  def handle_event("attention_lane_restore", params, socket) when is_map(params) do
    {:noreply,
     socket
     |> restore_lane(:lane_open, Map.get(params, "open"))
     |> restore_lane(:lane_coordinator, Map.get(params, "coordinator"))}
  end

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

  # ---- the install-wide concurrency cap ---------------------------------------

  # A blank value clears the override (back to the app-env / built-in default);
  # anything but a positive whole number is refused before the setter sees it.
  # The parsing and saving are `ArbiterWeb.InstallationSettings`', shared with
  # /settings.
  def handle_event("set_system_cap", params, socket) do
    case InstallationSettings.save_int("conductor_system_max_concurrent", params["max"]) do
      {:ok, _} ->
        {:noreply, refresh_board(socket)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, "Scheduler concurrency: #{message}")}
    end
  end

  # ---- the scheduler switch -------------------------------------------------

  # One switch for the whole install, because there is one scheduler. Pausing
  # leaves in-flight work alone — it only stops the queue draining.
  def handle_event("toggle_scheduler", _params, socket) do
    if InstallationSettings.scheduler_running?() do
      case InstallationSettings.toggle_scheduler() do
        :ok ->
          {:noreply, refresh_board(socket)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, InstallationSettings.scheduler_error(reason))}
      end
    else
      {:noreply, put_flash(socket, :error, InstallationSettings.scheduler_error(:not_running))}
    end
  end

  # ---- drag within a column: rank ------------------------------------------

  # The client resolves where in the column the card landed — before or after
  # the card under the cursor — because only it knows; the server decides what
  # that means against the board it rendered.
  def handle_event("reorder", %{"id" => id, "column" => column} = params, socket)
      when is_binary(id) and column in @rank_columns do
    {:noreply, reorder(socket, id, column, drop_target(params))}
  end

  def handle_event("reorder", _params, socket), do: {:noreply, socket}

  # ---- drag across columns --------------------------------------------------

  # The client reports the whole gesture — this card, out of that column, into
  # this one — and the board decides what it means.
  def handle_event("drag", %{"id" => id, "from" => from, "to" => to}, socket)
      when is_binary(id) and from in @column_keys and to in @column_keys do
    {:noreply, dropped(socket, id, from, to)}
  end

  def handle_event("drag", _params, socket), do: {:noreply, socket}

  # ---- what a landing means ------------------------------------------------

  # A card put back down on the column it came from did nothing.
  defp dropped(socket, _id, same, same), do: socket

  # bd-abg443: a quota-held ticket reads Blocked but is still active work the
  # queue resumes by itself; no drag turns it into queued or backlog work.
  defp dropped(%{assigns: %{board: board}} = socket, id, "blocked", to) do
    if Enum.any?(board.blocked, &(&1.id == id and is_map(&1[:hold]))),
      do: put_flash(socket, :error, "#{id} is held by the quota gate and resumes by itself."),
      else: drop_other(socket, id, "blocked", to)
  end

  defp dropped(socket, id, from, to), do: drop_other(socket, id, from, to)

  defp drop_other(socket, id, "backlog", to) when to in @queued_columns, do: promote(socket, id)

  defp drop_other(socket, id, from, "backlog") when from in @queued_columns,
    do: demote(socket, id)

  defp drop_other(socket, id, from, to), do: put_flash(socket, :error, refusal(id, from, to))

  defp refusal(id, from, to) do
    "#{id} cannot be dragged from #{column_label(from)} to #{column_label(to)}: " <>
      refusal_reason(from, to)
  end

  defp refusal_reason(from, to) when from in @queued_columns and to in @queued_columns,
    do: "whether a queued ticket is Blocked or Ready is decided by its dependencies."

  defp refusal_reason(_from, "in_progress"),
    do:
      "the scheduler dispatches the top Ready card when a slot frees up, and its card " <>
        "says what it is waiting for."

  defp refusal_reason(_from, _to),
    do:
      "only Backlog ⇄ Blocked/Ready is a drag (promote / demote). The rest of the " <>
        "lifecycle moves with the work — open the ticket to act on it."

  defp column_label(key), do: Enum.find_value(@columns, key, &(&1.key == key && &1.label))

  # Backlog → Blocked / Ready. Where it lands is its dependencies' call.
  defp promote(socket, id) do
    with {:ok, issue} <- Ash.get(Issue, id),
         {:ok, _promoted} <- Ash.update(issue, %{}, action: :promote) do
      socket
      |> put_flash(:info, "Promoted #{id} out of Backlog.")
      |> refresh_board()
    else
      {:error, err} ->
        put_flash(
          socket,
          :error,
          "#{id} stays in Backlog: #{ArbiterWeb.TaskForm.error_message(err)} " <>
            "The ticket's own page can promote it with a waiver reason."
        )
    end
  end

  # Blocked / Ready → Backlog.
  defp demote(socket, id) do
    with {:ok, issue} <- Ash.get(Issue, id),
         {:ok, _demoted} <- Ash.update(issue, %{}, action: :demote) do
      socket
      |> put_flash(:info, "Returned #{id} to Backlog.")
      |> refresh_board()
    else
      {:error, err} ->
        put_flash(socket, :error, "#{id} could not be demoted: " <> error_message(err))
    end
  end

  # ---- rank -----------------------------------------------------------------

  defp drop_target(%{"before_id" => id}) when is_binary(id) and id != "", do: {:before, id}
  defp drop_target(%{"after_id" => id}) when is_binary(id) and id != "", do: {:after, id}
  defp drop_target(_params), do: nil

  # Both cards must be in that column on the board the operator dragged on; a
  # drag against a board that has since moved changes nothing and re-reads.
  #
  # ES6: the board's bands are effective priority, so the band a card lands in
  # is the effective priority of the card it landed beside. A drop into a band
  # worse than the card's epic floor is refused (it would jump straight back);
  # any other drag pins the card and the cards above it in its band.
  defp reorder(socket, id, column, {where, target_id}) when id != target_id do
    cards = column_cards(socket.assigns.board, column)

    with %{} = card <- Enum.find(cards, &(&1.id == id)),
         %{} = target <- Enum.find(cards, &(&1.id == target_id)) do
      band = band_of(target)

      if below_floor?(card, band) do
        socket
        |> put_flash(:error, below_floor_message(card))
        |> refresh_board()
      else
        order = place(Enum.reject(cards, &(&1.id == id)), card, where, target_id)
        rerank(socket, card, band, rank_anchor(order, card), pin_prefix(order, card, band))
      end
    else
      _ -> refresh_board(socket)
    end
  end

  defp reorder(socket, _id, _column, _target), do: socket

  defp band_of(card), do: Map.get(card, :effective_priority) || card.priority

  # Only a lift that is in force refuses: a capped one orders by own priority.
  defp below_floor?(%{priority_lift: :applied} = card, band), do: band > band_of(card)
  defp below_floor?(_card, _band), do: false

  defp below_floor_message(card) do
    floor = band_of(card)

    "#{card.id} is lifted to P#{floor} by #{card.priority_via}'s floor — " <>
      "clear the floor or order it within P#{floor}"
  end

  # The cards above where the card landed, in its band, top first. They are
  # pinned with it (see `settle_prefix/1`) to keep the order the operator
  # produced: a pinned card sorts ahead of every unpinned one, so pinning the
  # card alone would send a drop at the bottom of a band to its top.
  defp pin_prefix(order, card, band) do
    order
    |> Enum.take_while(&(&1.id != card.id))
    |> Enum.filter(&(band_of(&1) == band))
  end

  defp place(cards, card, where, target_id) do
    Enum.flat_map(cards, fn
      %{id: ^target_id} = target when where == :before -> [card, target]
      %{id: ^target_id} = target -> [target, card]
      other -> [other]
    end)
  end

  # Rank is per workspace (`Changes.SetRank`), so the card is placed after the
  # nearest same-workspace card above where it landed, else before the nearest
  # one below. Alone in its workspace in this column, its rank has nothing to
  # be relative to here, and only its priority can move.
  defp rank_anchor(order, card) do
    {above, [_card | below]} = Enum.split_while(order, &(&1.id != card.id))
    same_ws? = &(&1.workspace_id == card.workspace_id)

    case {above |> Enum.reverse() |> Enum.find(same_ws?), Enum.find(below, same_ws?)} do
      {%{id: id}, _} -> %{after_id: id}
      {nil, %{id: id}} -> %{before_id: id}
      {nil, nil} -> nil
    end
  end

  # Dropping into another band moves the ticket's own priority into that band
  # first, then ranks and pins it where it landed. A lifted card dropped in its
  # floor's band keeps its own priority: it is already there.
  #
  # One transaction: the cards above are pinned (and, where their rank
  # disagrees with the order shown, re-ranked) together with the dragged card's
  # own move, so a refused move leaves none of it behind. Listeners hear about
  # the new order only once it is committed.
  defp rerank(socket, card, band, rank_args, prefix) do
    result =
      Arbiter.Repo.transaction(fn ->
        with {:ok, issue} <- Ash.get(Issue, card.id),
             {:ok, issue} <- reprioritise(issue, band_change(card, band)),
             :ok <- settle_prefix(prefix),
             {:ok, ranked} <- rank(issue, rank_args) do
          ranked
        else
          {:error, err} -> Arbiter.Repo.rollback(err)
        end
      end)

    case result do
      {:ok, ranked} ->
        # `:set_rank` announces nothing of its own; every other board, and
        # Autopilot's next plan, should see the new order.
        Issue.broadcast_lifecycle(:updated, ranked)

        socket
        |> then(fn socket ->
          if is_integer(band) and band != band_of(card),
            do: put_flash(socket, :info, "Moved #{card.id} to P#{band}."),
            else: socket
        end)
        |> refresh_board()

      {:error, err} ->
        socket
        |> put_flash(:error, "Could not reorder #{card.id}: " <> error_message(err))
        |> refresh_board()
    end
  end

  defp band_change(card, band), do: if(band == band_of(card), do: card.priority, else: band)

  # Walks the cards above the drop, top first, so that every one of them is
  # pinned and their ranks ascend in the order shown. A pin survives changes
  # that put a card first in a new band without a drag (an own-priority edit,
  # a floor set or cleared), so a pinned card's rank can disagree with its
  # place; such a card, like any whose rank is not past the card shown above
  # it in the same workspace, is ranked after that card. Rank is per
  # workspace, so only same-workspace cards compare.
  defp settle_prefix(prefix) do
    prefix
    |> Enum.reduce_while({:ok, %{}}, fn card, {:ok, last_by_ws} ->
      case settle_card(card, Map.get(last_by_ws, card.workspace_id)) do
        {:ok, settled} -> {:cont, {:ok, Map.put(last_by_ws, card.workspace_id, settled.id)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _last_by_ws} -> :ok
      {:error, _} = error -> error
    end
  end

  defp settle_card(card, above_id) do
    with {:ok, issue} <- Ash.get(Issue, card.id),
         {:ok, above} <- fetch_above(above_id) do
      cond do
        above != nil and issue.rank <= above.rank ->
          Rank.move(issue, %{after_id: above.id, pin: true})

        issue.rank_pinned ->
          {:ok, issue}

        true ->
          Ash.update(issue, %{pinned: true}, action: :set_rank_pinned)
      end
    end
  end

  defp fetch_above(nil), do: {:ok, nil}
  defp fetch_above(id), do: Ash.get(Issue, id)

  defp reprioritise(%Issue{priority: same} = issue, same), do: {:ok, issue}

  defp reprioritise(issue, band) when is_integer(band),
    do: Ash.update(issue, %{priority: band})

  defp reprioritise(issue, _band), do: {:ok, issue}

  # `rank_pinned`: the drag pins the card with its move. Alone in its
  # workspace (`nil` args) there is nothing to rank against, but it is still
  # pinned in its band.
  defp rank(issue, nil), do: Ash.update(issue, %{pinned: true}, action: :set_rank_pinned)
  defp rank(issue, args), do: Rank.move(issue, Map.put(args, :pin, true))

  defp error_message(err) when is_binary(err), do: err
  defp error_message(err), do: ArbiterWeb.TaskForm.error_message(err)

  # A column's cards in their displayed order, before any view filter.
  defp column_cards(board, "ready"), do: Enum.map(board.ready, & &1.card)
  defp column_cards(board, "backlog"), do: board.backlog

  # ---- the lane's per-viewer settings ----------------------------------------

  defp restore_lane(socket, key, value) when is_boolean(value), do: assign(socket, key, value)
  defp restore_lane(socket, _key, _value), do: socket

  defp push_lane_pref(socket) do
    push_event(socket, "attention_lane_pref", %{
      open: socket.assigns.lane_open,
      coordinator: socket.assigns.lane_coordinator
    })
  end

  # ---- reads ----------------------------------------------------------------

  # The board the *scheduler* sees, so the reasons on screen are the reasons it
  # is acting on — but derived by this LiveView, not fetched from the
  # autopilot. The only thing that process contributes to a board read is the
  # pause flag, and asking it for the whole snapshot would put every open
  # board behind one mailbox.
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

  defp worker_debounce_ms,
    do: Application.get_env(:arbiter_web, :board_worker_debounce_ms, 500)

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
    running? = InstallationSettings.scheduler_running?()
    paused? = not running? or InstallationSettings.scheduler_paused?()

    board =
      Snapshot.load(now: DateTime.utc_now(), paused: paused?, exclude_engagements?: true)

    exit_if_view_gone()
    alerts = load_alerts()
    exit_if_view_gone()
    workspaces = load_workspaces()
    exit_if_view_gone()

    %{
      board: board,
      alerts: alerts,
      paused_providers: Arbiter.Providers.Pause.list(),
      local_cap_zero?: local_cap_zero?(),
      scheduler_running: running?,
      workspaces: workspaces,
      system_cap: Snapshot.system_max_concurrent(),
      system_cap_override?: is_integer(Settings.conductor_system_max_concurrent())
    }
  end

  # RW8: the primary's own worker cap is overridden to 0 — nothing runs on this
  # machine, so local-only work (reviewers, fix and conflict passes, agy/codex,
  # research) is held until a node or the cap frees a slot.
  defp local_cap_zero? do
    match?(%{cap: 0, enforced?: true}, Arbiter.Nodes.LocalCapacity.cap())
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

  # The swimlane's system alerts. Their failure is not the board's: a lane
  # without alerts still shows every ticket's attention.
  defp load_alerts do
    Arbiter.Alerts.active()
  rescue
    _ -> []
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

  # One list of cards per column, ready to render. A Ready entry's card takes
  # its queue reason and standing along.
  defp column_items(assigns, %{board_key: :ready}) do
    assigns.board.ready
    |> Enum.map(&Map.merge(&1.card, %{reason: &1.reason, queue_state: &1.state}))
    |> Enum.filter(&matches?(&1, assigns))
  end

  defp column_items(assigns, %{board_key: key}) do
    assigns.board |> Map.get(key, []) |> Enum.filter(&matches?(&1, assigns))
  end

  # The swimlane: ticket attention, operator-owned unless the coordinator chip
  # is on, and the system alerts under the same rule.
  defp lane_tickets(assigns) do
    assigns.board
    |> Map.get(:attention, [])
    |> Enum.filter(&(lane_owner?(&1.owner, assigns) and matches?(&1, assigns)))
  end

  defp lane_alerts(assigns) do
    Enum.filter(assigns.alerts, fn alert ->
      lane_owner?(alert.owner, assigns) and
        (is_nil(alert.workspace_id) or matches_workspace?(alert, assigns.workspace))
    end)
  end

  defp lane_owner?(:operator, _assigns), do: true
  defp lane_owner?(_owner, assigns), do: assigns.lane_coordinator

  defp matches?(card, assigns) do
    matches_workspace?(card, assigns.workspace) and matches_filter?(card, assigns.filter)
  end

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

  # ---- formatting -----------------------------------------------------------

  # bd-aw2cyt: how many agents are actually burning quota. `agents_live` is
  # what `Snapshot.derive/1` counted; an older board map (a stubbed snapshot in
  # a test, a replayed payload) falls back to the number of In-progress cards.
  defp agents_live(board),
    do: Map.get(board, :agents_live) || length(Map.get(board, :in_progress, []))

  # bd-45pwo1: what the dispatch cap actually measures — one per ticket In
  # progress, not one per live agent. An older board map without the key falls
  # back to `slots_total - slots_free`, which `slots_free` was computed from.
  defp slots_used(board) do
    Map.get(board, :slots_used) ||
      max(Map.get(board, :slots_total, 0) - Map.get(board, :slots_free, 0), 0)
  end

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
  # state that owns it right now, and money is a second axis. Open cards only:
  # `Snapshot.derive/1` never sets it on a closed one.
  defp over_budget_flag(assigns) do
    ~H"""
    <span
      data-over-budget
      title="worker spend is past the p90 of what tickets like this cost — excludes coordinator session overhead"
      aria-label="over budget"
      class="hero-banknotes"
      style="width: 11px; height: 11px; background-color: var(--arb-fail);"
    />
    """
  end

  defp quota_note({:hold, reason}), do: reason
  defp quota_note(_), do: nil

  defp board_state(_loaded?, error) when is_binary(error), do: "error"
  defp board_state(true, nil), do: "loaded"
  defp board_state(false, nil), do: "loading"

  # A few placeholder cards per skeleton column, uneven so it reads as a
  # board rather than a grid.
  defp skeleton_cards("ready"), do: ["h-[74px]", "h-[74px]", "h-[74px]"]
  defp skeleton_cards("in_progress"), do: ["h-[92px]", "h-[92px]"]
  defp skeleton_cards("merging"), do: ["h-[74px]"]
  defp skeleton_cards(_), do: ["h-[62px]", "h-[62px]"]

  defp scheduler_label(%{paused: true}), do: "paused"
  defp scheduler_label(_), do: "auto"

  # The one column head that carries a hue is the one whose state is the
  # machine's live work.
  defp head_hue("live"), do: "var(--arb-live)"
  defp head_hue(_), do: nil

  defp column_count(%{key: "in_progress"}, items, board),
    do: "#{length(items)} / #{board.slots_total}"

  defp column_count(_column, items, _board), do: length(items)

  # ---- card content, per column ----------------------------------------------

  # The column's one line about the card (see the moduledoc).
  defp detail("blocked", %{hold: %{reason: reason}}), do: reason
  defp detail("blocked", card), do: EdgeGate.describe({:waiting_on, card.blocked_by})
  defp detail("ready", card), do: ready_reason(card.reason)

  defp detail(column, %{step: :awaiting_ci, ci_wait: %{sha: _} = wait})
       when column in ["in_progress", "merging"],
       do: Arbiter.Worker.ReviewCi.wait_label(wait)

  defp detail(column, card) when column in ["in_progress", "merging"], do: step_label(card.step)
  defp detail("verifying", _card), do: "awaiting verification — restart & observe"
  defp detail("closed", card), do: close_reason_label(Map.get(card, :close_reason))
  defp detail(_column, _card), do: nil

  # The scheduler words a hold as `blocked — …`, which on this board would
  # read as the Blocked column's business. A Ready card is *held*, not blocked.
  defp ready_reason("blocked — " <> hold), do: "held — " <> hold
  defp ready_reason(reason), do: reason

  defp step_label(nil), do: nil
  defp step_label(step), do: Map.get(@step_labels, step, to_string(step))

  defp close_reason_label(nil), do: "closed"
  defp close_reason_label(reason), do: Map.get(@close_reason_labels, reason, to_string(reason))

  # The activity line: what an In-progress card's run is doing (linked to its
  # worker when a run is live), the PR a Merging card is on.
  defp activity("in_progress", card), do: Map.get(card, :activity)
  defp activity("merging", card), do: Map.get(card, :mr_ref) || Map.get(card, :activity)
  defp activity(_column, _card), do: nil

  #
  # Where the line goes is where the next move is made: a card built from a
  # run (its `status` is the run's state; a workerless card has none) goes to
  # that worker, live or parked; a Merging card to the merge queue — unless
  # its Watchdog is gone or was pulled (bd-8jixav), whose restart lives on the
  # worker page.
  defp activity_href("in_progress", %{status: status} = card) when not is_nil(status),
    do: ~p"/workers/#{card.id}"

  defp activity_href("merging", %{step: :awaiting_ci} = card), do: ~p"/workers/#{card.id}"
  defp activity_href("merging", %{merge_pulled: true} = card), do: ~p"/workers/#{card.id}"
  defp activity_href("merging", %{watchdog_alive: false} = card), do: ~p"/workers/#{card.id}"
  defp activity_href("merging", _card), do: ~p"/merge_queue"
  defp activity_href(_column, _card), do: nil

  defp footer("backlog", card, now), do: relative(card.created_at, now)
  defp footer("closed", card, _now), do: "closed #{clock(card.closed_at)}"

  defp footer(column, card, _now) when column in ["merging", "in_progress"],
    do: card.collapsed_note

  defp footer(_column, _card, _now), do: nil

  defp accent("ready", %{queue_state: :next}), do: "live"
  defp accent("in_progress", %{live: true}), do: "live"
  defp accent(_column, _card), do: nil

  defp card_type(column, card) when column in ["backlog", "blocked", "ready"],
    do: Map.get(card, :issue_type)

  defp card_type(_column, _card), do: nil

  defp owner_label(:operator), do: "you"
  defp owner_label(:coordinator), do: "coordinator"
  defp owner_label(other), do: to_string(other)

  defp alert_kind_label(kind), do: kind |> to_string() |> String.replace("_", " ")

  # ---- render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:items, Map.new(@columns, &{&1.key, column_items(assigns, &1)}))
      |> assign(:lane_tickets, lane_tickets(assigns))
      |> assign(:lane_alerts, lane_alerts(assigns))

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

              <form
                :if={@board_loaded?}
                id="board-concurrency-form"
                phx-submit="set_system_cap"
                class="hidden sm:flex items-center gap-1.5"
              >
                <span
                  id="board-concurrency"
                  data-override={to_string(@system_cap_override?)}
                  title="Install-wide scheduler concurrency cap. Leave blank to use the default."
                  class="flex items-center gap-1.5 text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
                >
                  <label for="board-concurrency-input">max concurrent</label>
                  <input
                    id="board-concurrency-input"
                    name="max"
                    type="text"
                    inputmode="numeric"
                    autocomplete="off"
                    value={if(@system_cap_override?, do: @system_cap, else: "")}
                    placeholder={to_string(@system_cap)}
                    class="w-12 px-1.5 py-[2px] rounded-[var(--radius-chip)] border border-solid border-[var(--border-default)] bg-transparent text-[11px] text-[var(--text-primary)]"
                  />
                  <span :if={not @system_cap_override?}>(default)</span>
                  <button
                    id="board-concurrency-save"
                    type="submit"
                    class="cursor-pointer px-1.5 py-[2px] rounded-[var(--radius-chip)] border border-solid border-[var(--border-default)] text-[10px] uppercase tracking-[0.08em] hover:text-[var(--text-primary)] transition-colors"
                  >
                    save
                  </button>
                </span>
                <span
                  :if={@board.slots_total < @system_cap}
                  id="board-concurrency-limited"
                  title="A workspace or provider-account cap is lower than the scheduler cap."
                  class="text-[10px] text-[var(--arb-attention)] font-[family-name:var(--font-mono)]"
                >
                  board limited to {@board.slots_total} by workspace/account cap
                </span>
              </form>

              <.link
                :if={@board_loaded? and @local_cap_zero?}
                id="board-local-cap-zero"
                navigate={~p"/nodes"}
                title="The local cap is 0: nothing runs on this machine. Work that can only run here (reviewers, fix and conflict passes, agy/codex runs, research) is held until a local slot opens."
                class="px-2 py-[3px] rounded-[var(--radius-chip)] border border-solid border-[var(--arb-attention)] text-[10px] font-medium font-[family-name:var(--font-mono)] uppercase tracking-[0.08em] text-[var(--arb-attention)]"
              >
                local cap 0 — local-only work waits
              </.link>

              <.link
                :if={@board_loaded? and @paused_providers != []}
                id="board-paused-providers"
                navigate={~p"/providers"}
                title={
                  Enum.map_join(@paused_providers, "; ", fn p ->
                    "#{Arbiter.Providers.Pause.label(p.target)}: #{p.reason || "no reason given"} (by #{p.by || "unknown"})"
                  end)
                }
                class="px-2 py-[3px] rounded-[var(--radius-chip)] border border-solid border-[var(--arb-fail-edge)] text-[10px] font-medium font-[family-name:var(--font-mono)] uppercase tracking-[0.08em] text-[var(--arb-fail-text)]"
              >
                {length(@paused_providers)} provider(s) paused
              </.link>

              <%!-- Until the first read lands there is no scheduler state to
                   show, and a "paused" guess would be a claim. --%>
              <button
                :if={@board_loaded?}
                id="board-scheduler-toggle"
                type="button"
                phx-click="toggle_scheduler"
                data-confirm={
                  unless @board.paused,
                    do:
                      "Pause the scheduler? Ready cards will stop being promoted until it is resumed."
                }
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

          <%!-- ── Needs attention ─────────────────────────────────────
               Always in the DOM, so its hook can restore the viewer's own
               setting before the first board read lands. --%>
          <section
            id="board-attention-lane"
            phx-hook=".AttentionLane"
            aria-label="Needs attention"
            data-open={to_string(@lane_open)}
            class="border-b border-solid border-[var(--border-default)] bg-[var(--surface-page)]"
          >
            <div class="flex flex-wrap items-center gap-2 px-4 py-2">
              <button
                id="board-attention-toggle"
                type="button"
                phx-click="toggle_attention_lane"
                aria-expanded={to_string(@lane_open)}
                aria-controls="board-attention-items"
                class="group inline-flex items-center gap-1.5 cursor-pointer text-[10.5px] font-medium uppercase tracking-[0.1em] font-[family-name:var(--font-mono)] text-[var(--text-secondary)] hover:text-[var(--text-title)] transition-colors"
              >
                <span
                  aria-hidden="true"
                  class={[
                    "hero-chevron-right-micro size-3.5 transition-transform duration-[var(--dur-hover)]",
                    @lane_open && "rotate-90"
                  ]}
                /> Needs attention
                <span
                  id="board-attention-count"
                  class={[
                    "min-w-[18px] px-1.5 py-px rounded-[var(--radius-pill)] text-center normal-case tracking-normal",
                    if(@lane_tickets != [] or @lane_alerts != [],
                      do:
                        "bg-[color-mix(in_oklch,var(--arb-attention)_18%,transparent)] text-[var(--arb-attention)]",
                      else: "bg-[var(--arb-canvas-sunken)] text-[var(--text-label)]"
                    )
                  ]}
                >
                  {if @board_loaded?, do: length(@lane_tickets) + length(@lane_alerts), else: "·"}
                </span>
              </button>

              <button
                id="board-attention-coordinator"
                type="button"
                phx-click="toggle_attention_coordinator"
                aria-pressed={to_string(@lane_coordinator)}
                title="Also show what the coordinator agent is working through"
                class={[
                  "ml-1 px-2 py-[2px] rounded-[var(--radius-chip)] border border-solid cursor-pointer transition-colors",
                  "text-[10px] font-medium font-[family-name:var(--font-mono)]",
                  if(@lane_coordinator,
                    do:
                      "border-[color-mix(in_oklch,var(--arb-info)_45%,transparent)] text-[var(--arb-info)] bg-[color-mix(in_oklch,var(--arb-info)_10%,transparent)]",
                    else:
                      "border-[var(--border-strong)] text-[var(--text-label)] hover:text-[var(--text-secondary)]"
                  )
                ]}
              >
                + coordinator
              </button>
            </div>

            <div
              :if={@lane_open and @board_loaded?}
              id="board-attention-items"
              class="flex gap-2 overflow-x-auto px-4 pb-3"
            >
              <div
                :for={alert <- @lane_alerts}
                id={"lane-alert-#{alert.id}"}
                data-lane-item="alert"
                data-owner={alert.owner}
                class="flex-none w-64 flex flex-col gap-1 px-[11px] py-[9px] rounded-[var(--radius-field)] border border-solid border-[var(--arb-fail-edge)] bg-[var(--arb-fail-wash)]"
              >
                <span class="flex items-center gap-1.5 text-[10px] font-medium uppercase tracking-[0.08em] font-[family-name:var(--font-mono)] text-[var(--arb-fail-text)]">
                  <span aria-hidden="true" class="hero-bell-alert-micro size-3.5" />
                  {alert_kind_label(alert.kind)}
                  <span class="ml-auto normal-case tracking-normal text-[var(--text-label)]">
                    {elapsed(alert.raised_at, @now)}
                  </span>
                </span>
                <span class="text-[12px] font-medium leading-[1.4] text-[var(--text-title)]">
                  {alert.subject || alert.key}
                </span>
                <span
                  :if={alert.detail}
                  class="text-[11px] leading-[1.45] text-[var(--text-secondary)] line-clamp-2"
                  title={alert.detail}
                >
                  {alert.detail}
                </span>
              </div>

              <.link
                :for={item <- @lane_tickets}
                id={"lane-ticket-#{item.id}"}
                navigate={~p"/tasks/#{item.id}"}
                data-lane-item="ticket"
                data-owner={item.owner}
                class={[
                  "flex-none w-64 flex flex-col gap-1 px-[11px] py-[9px]",
                  "rounded-[var(--radius-field)] border border-solid bg-[var(--surface-card)]",
                  "transition-colors duration-[var(--dur-hover)] hover:bg-[var(--arb-canvas-sunken)]",
                  "no-underline text-inherit",
                  if(item.owner == :operator,
                    do: "border-[color-mix(in_oklch,var(--arb-attention)_45%,transparent)]",
                    else: "border-[var(--arb-line)]"
                  )
                ]}
              >
                <span class="flex items-center gap-1.5 text-[10.5px] font-[family-name:var(--font-mono)]">
                  <span class="font-medium text-[var(--text-secondary)]">{item.id}</span>
                  <span class="text-[var(--text-label)]">
                    · {column_label(Atom.to_string(item.column))}
                  </span>
                  <span class="ml-auto text-[var(--text-label)]">{elapsed(item.since, @now)}</span>
                </span>
                <span class="text-[12px] font-medium leading-[1.4] text-[var(--text-title)] line-clamp-2">
                  {item.title || item.id}
                </span>
                <.attention_marker attention={item} />
              </.link>

              <div
                :if={@lane_tickets == [] and @lane_alerts == []}
                id="board-attention-empty"
                class="px-2 py-1 text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
              >
                {if @lane_coordinator,
                  do: "nothing needs attention",
                  else: "nothing needs you — the coordinator has the rest"}
              </div>
            </div>
          </section>

          <%!-- ── Skeleton ────────────────────────────────────────────
               The first read is out: the seven columns, with nothing claimed
               about what is in them. --%>
          <div
            :if={not @board_loaded? and is_nil(@board_error)}
            id="board-loading"
            aria-label="Loading the board"
            class="flex overflow-x-auto snap-x snap-mandatory gap-px bg-[var(--arb-line-soft)] min-h-[560px] 2xl:grid 2xl:grid-cols-[repeat(7,minmax(16rem,1fr))]"
          >
            <div
              :for={column <- @columns}
              id={"board-loading-#{column.key}"}
              class="flex-shrink-0 w-[85vw] md:w-64 snap-start bg-[var(--surface-page)] px-3 pt-3 pb-4 flex flex-col gap-[9px] 2xl:w-auto 2xl:min-w-0"
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
            class="flex overflow-x-auto snap-x snap-mandatory gap-px bg-[var(--arb-line-soft)] min-h-[560px] 2xl:grid 2xl:grid-cols-[repeat(7,minmax(16rem,1fr))]"
          >
            <div
              :for={column <- @columns}
              id={"board-column-#{column.key}"}
              data-column={column.key}
              class="flex-shrink-0 w-[85vw] md:w-64 snap-start bg-[var(--surface-page)] px-3 pt-3 pb-4 flex flex-col gap-[9px] 2xl:w-auto 2xl:min-w-0"
            >
              <.column_head
                label={column.label}
                count={column_count(column, @items[column.key], @board)}
                tone={column.tone}
              />

              <div
                :for={card <- Enum.take(@items[column.key], limit(@expanded, column.key))}
                id={"card-#{card.id}"}
                class="contents"
                phx-click={JS.navigate(task_navigate_href(card))}
              >
                <.board_card card={card} column={column.key} now={@now} />
              </div>

              <.more
                :if={length(@items[column.key]) > limit(@expanded, column.key)}
                column={column.key}
                count={length(@items[column.key]) - limit(@expanded, column.key)}
              />

              <div
                :if={column.key == "backlog" and @items["backlog"] == []}
                id="board-backlog-empty"
                class="mt-auto px-2 py-2 text-center rounded-[var(--radius-field)] border border-dashed border-[var(--border-strong)] text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
              >
                nothing waiting to be refined
              </div>

              <%!-- Where the handoff put "drop to dispatch". The queue drains
                   itself, so what belongs here is the reason it might not. --%>
              <div
                :if={column.key == "ready"}
                id="board-ready-foot"
                class="mt-auto px-2 py-2 text-center rounded-[var(--radius-field)] border border-dashed border-[var(--border-strong)] text-[11px] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
              >
                {ready_foot(@board, @scheduler_running)}
              </div>
            </div>
          </div>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".AttentionLane">
        // The swimlane's open/closed state and its coordinator chip are one
        // viewer's convenience, so they live in that viewer's browser storage.
        // Storage can be missing or throw (private mode, a blocked
        // localStorage): then nothing is restored and nothing is stored, and
        // the lane keeps the server's defaults.
        const KEY = "arbiter:board:attention-lane"

        export default {
          mounted() {
            let pref = null
            try {
              pref = JSON.parse(window.localStorage.getItem(KEY) || "null")
            } catch (_) {
              pref = null
            }
            if (pref && typeof pref === "object") {
              this.pushEvent("attention_lane_restore", pref)
            }

            this.handleEvent("attention_lane_pref", (next) => {
              try {
                window.localStorage.setItem(KEY, JSON.stringify(next))
              } catch (_) {}
            })
          },
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".BoardDrag">
        // Drag is a human action. Within Backlog or Ready it re-ranks: only
        // the client knows where the cursor landed, so it names the card the
        // drop went before or after. Across columns it reports the whole
        // gesture, and the server decides what — if anything — it means.
        const RANKED = ["backlog", "ready"]

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
              // Mandatory snapping re-snaps every programmatic scroll back to
              // the current column edge, so edge auto-scroll needs it off.
              el.style.scrollSnapType = "none"
              e.dataTransfer.effectAllowed = "move"
              try { e.dataTransfer.setData("text/plain", card.dataset.card) } catch (_) {}
            })

            el.addEventListener("dragover", (e) => {
              if (!this.dragging) return
              e.preventDefault()

              // The row scrolls sideways: nudge it when the cursor nears an
              // edge so a column that starts off-screen can be reached.
              const box = el.getBoundingClientRect()
              const EDGE = 64
              if (e.clientX < box.left + EDGE) el.scrollLeft -= 24
              else if (e.clientX > box.right - EDGE) el.scrollLeft += 24
            })

            // dragend also fires for a cancelled drag, which never drops.
            el.addEventListener("dragend", () => {
              this.dragging = null
              el.style.scrollSnapType = ""
            })

            el.addEventListener("drop", (e) => {
              const drag = this.dragging
              this.dragging = null
              el.style.scrollSnapType = ""
              if (!drag) return
              e.preventDefault()

              const column = e.target.closest("[data-column]")
              if (!column) return
              const to = column.dataset.column

              if (to === drag.from && RANKED.includes(to)) {
                this.rank(drag, column, e)
                return
              }

              this.pushEvent("drag", {id: drag.id, from: drag.from, to: to})
            })
          },
          rank(drag, column, e) {
            const over = e.target.closest("[data-card]")

            if (over && over.dataset.card !== drag.id) {
              const box = over.getBoundingClientRect()
              const after = e.clientY > box.top + box.height / 2
              const key = after ? "after_id" : "before_id"
              this.pushEvent("reorder", {id: drag.id, column: drag.from, [key]: over.dataset.card})
              return
            }

            // Dropped on the column's empty space: to the bottom.
            if (!over) {
              const ids = Array.from(column.querySelectorAll("[data-card]"))
                .map((n) => n.dataset.card)
                .filter((id) => id !== drag.id)
              const last = ids[ids.length - 1]
              if (last) this.pushEvent("reorder", {id: drag.id, column: drag.from, after_id: last})
            }
          },
        }
      </script>
    </Layouts.app>
    """
  end

  # ---- render helpers -------------------------------------------------------

  # ES5 (design §6.3): the chip says `· floor P1` only when the floor lifting
  # this card comes from the chip's own parent; a further ancestor is named in
  # the badge's title instead.
  defp chip_floor(%{priority_lift: :applied, priority_via: via, effective_priority: eff} = card)
       when is_integer(eff) do
    case card[:parent] do
      %{id: ^via} -> eff
      _ -> nil
    end
  end

  defp chip_floor(_card), do: nil

  attr(:card, :map, required: true)
  attr(:column, :string, required: true)
  attr(:now, :any, required: true)

  # One card, any column. What differs per column is read through the
  # `detail/2`, `activity/2`, `footer/3` and `accent/2` helpers above rather
  # than seven copies of the markup.
  defp board_card(assigns) do
    assigns =
      assign(assigns,
        detail: detail(assigns.column, assigns.card),
        activity: activity(assigns.column, assigns.card),
        activity_href: activity_href(assigns.column, assigns.card),
        footer: footer(assigns.column, assigns.card, assigns.now)
      )

    ~H"""
    <.task_card
      id={@card.id}
      title={@card.title || @card.id}
      priority={if @column != "closed", do: @card[:priority]}
      lift={if @column != "closed", do: @card}
      type={card_type(@column, @card)}
      difficulty={if @column == "closed", do: :unset, else: @card[:difficulty]}
      accent={accent(@column, @card)}
      activity={@activity}
      activity_href={@activity_href}
      footer={@footer}
      muted={@column == "closed"}
      draggable="true"
      class="cursor-pointer"
      data-card={@card.id}
      data-column={@column}
    >
      <:parent :if={@card[:parent]}>
        <.parent_link parent={@card.parent} mode="compact" floor={chip_floor(@card)} />
      </:parent>
      <:status>
        <span class="flex items-center gap-1.5">
          <.over_budget_flag :if={@card[:over_budget]} />
          <.provider_icon
            :if={@column == "in_progress" and @card[:provider]}
            provider={@card.provider}
            class="size-3.5 text-[var(--text-label)]"
          />
          <%!-- bd-aw2cyt: the pulse is a claim that something is running.
               Only a card with a live agent gets it. --%>
          <span
            :if={@column in ["in_progress", "merging", "verifying"]}
            data-phase={@card[:phase]}
            data-agent-live={to_string(@card[:agent_live] == true)}
            class={[
              "text-[10px] font-medium font-[family-name:var(--font-mono)]",
              if(@card[:agent_live],
                do:
                  "text-[var(--arb-live)] animate-[arb-pulse_var(--pulse-period)_var(--ease-in-out)_infinite]",
                else: "text-[var(--text-label)] opacity-70"
              )
            ]}
          >
            {elapsed(@card[:since], @now)}
          </span>
        </span>
      </:status>
      <:detail :if={@detail}>
        <span
          data-detail={@column}
          data-step={@card[:step]}
          data-close-reason={@column == "closed" && @card[:close_reason]}
          data-queue-state={@card[:queue_state]}
          class={[
            "text-[10.5px] leading-[1.5] font-[family-name:var(--font-mono)]",
            detail_class(@column, @card)
          ]}
        >
          {@detail}
        </span>
      </:detail>
      <:actions :if={
        @card[:attention] || @column == "backlog" || ArbiterWeb.DemoteEntry.eligible?(@card)
      }>
        <span class="flex flex-col gap-1.5 w-full">
          <.attention_marker :if={@card[:attention]} attention={@card.attention} />
          <span :if={@column == "backlog"} class="flex gap-1.5">
            <%!-- Refine (bd-1lszsc). Nesting it inside the card's own
                 `phx-click` navigation is safe: LiveView resolves a click to
                 the *nearest* `phx-click` ancestor. --%>
            <ArbiterWeb.RefineEntry.refine_button
              id={"board-refine-#{@card.id}"}
              issue_id={@card.id}
              variant="ghost"
            />
          </span>
          <span :if={@column == "ready" and ArbiterWeb.DemoteEntry.eligible?(@card)} class="flex">
            <ArbiterWeb.DemoteEntry.demote_button
              id={"board-demote-#{@card.id}"}
              issue_id={@card.id}
              variant="ghost"
            />
          </span>
        </span>
      </:actions>
    </.task_card>
    """
  end

  defp detail_class("ready", %{queue_state: :next}), do: "text-[var(--arb-live)]"
  defp detail_class("ready", %{queue_state: :blocked}), do: "text-[var(--arb-attention)]"
  defp detail_class("blocked", _card), do: "text-[var(--arb-attention)]"
  defp detail_class("in_progress", %{live: true}), do: "text-[var(--text-secondary)]"
  defp detail_class(_column, _card), do: "text-[var(--text-label)]"

  attr(:attention, :map, required: true)

  # Who has to act, and why — on a card in its own column, and on its lane
  # card. The operator's is the only one that takes the attention hue.
  defp attention_marker(assigns) do
    ~H"""
    <span
      data-attention={@attention.owner}
      title={@attention[:note] || @attention.reason}
      class={[
        "inline-flex items-start gap-1 max-w-full px-1.5 py-[3px] rounded-[var(--radius-chip)] border border-solid",
        "text-[10px] leading-[1.35] font-[family-name:var(--font-mono)]",
        if(@attention.owner == :operator,
          do:
            "border-[color-mix(in_oklch,var(--arb-attention)_45%,transparent)] bg-[color-mix(in_oklch,var(--arb-attention)_10%,transparent)] text-[var(--arb-attention)]",
          else: "border-[var(--arb-line)] text-[var(--text-secondary)]"
        )
      ]}
    >
      <span aria-hidden="true" class="hero-flag-micro size-3 shrink-0 mt-px" />
      <span class="min-w-0">
        <span class="font-medium">{owner_label(@attention.owner)}</span> · {@attention.reason}
      </span>
    </span>
    """
  end

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
      class="flex items-center justify-between px-[11px] py-[9px] rounded-[var(--radius-field)] border border-dashed border-[var(--arb-line)] cursor-pointer hover:bg-[var(--arb-canvas-sunken)] transition-colors"
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
