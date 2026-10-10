defmodule ArbiterWeb.CapacityComponents do
  @moduledoc """
  The board's capacity strip and a Ready card's layer reason (DC5, bd-2c2a4g;
  `docs/design/provider-dynamic-concurrency.md` §9).

  `<.capacity_strip>` is `#board-capacity`: one chip per provider pool
  (`#pool-chip-<account>-<pool>`, "claude 3/3", "agy gemini 0/0") and per
  machine (`#node-chip-<name>`, "local 3/6"). A chip is one of free, full, held
  by pace or held by a hard rule (`data-chip-state`), and opens a popup that
  says why the budget is what it is: the reason, the binding window with every
  number behind it, the ceiling, a pending rise, the exempt budget, who holds
  the seats, the recent changes and the command that changes the ceiling.

  It renders `Arbiter.Board.CapacityView.status/1` as it is, and only shows it.
  Under `scheduler_admission: legacy` and `shadow` the budgets decide nothing,
  so the strip says so; only `enforce` drops that note.

  `<.layer_reason>` is the line on a Ready card the scheduler walk would hold
  or start: the layer's own phrase ("Waiting for claude:default: 3 of 3 seats"),
  prefixed "Shadow walk" until the walk decides.
  """
  use ArbiterWeb, :html

  attr :capacity, :map, required: true, doc: "`Arbiter.Board.CapacityView.status/1`"

  def capacity_strip(assigns) do
    assigns = assign(assigns, :admission, assigns.capacity.admission)

    ~H"""
    <span
      id="board-capacity"
      data-admission={@admission.mode}
      class="inline-flex flex-wrap items-center gap-1.5 text-[11px] font-[family-name:var(--font-mono)]"
    >
      <span
        id="board-capacity-mode"
        title={mode_title(@admission)}
        class={[
          "px-[6px] py-[1px] rounded-[var(--radius-chip)] border border-solid text-[10px] font-medium uppercase tracking-[0.06em]",
          if(@admission.decides,
            do: "border-[var(--arb-live)] text-[var(--arb-live)]",
            else: "border-[var(--border-default)] text-[var(--text-label)]"
          )
        ]}
      >
        {@admission.label}
      </span>
      <span
        :if={not @admission.decides}
        id="board-capacity-mode-note"
        class="hidden 2xl:inline text-[10px] text-[var(--text-label)]"
      >
        today's gate and caps still decide
      </span>
      <.pool_chip :for={pool <- @capacity.pools} pool={pool} admission={@admission} />
      <.node_chip :for={machine <- @capacity.machines} machine={machine} />
    </span>
    """
  end

  defp mode_title(%{decides: true}),
    do: "Budgets admit dispatches (scheduler_admission: enforce)."

  defp mode_title(%{mode: mode}),
    do:
      "scheduler_admission: #{mode}. Budgets are shown and recorded beside today's decision; " <>
        "today's gate and caps still decide."

  # ---- a provider pool ----------------------------------------------------------

  attr :pool, :map, required: true
  attr :admission, :map, required: true

  defp pool_chip(assigns) do
    ~H"""
    <.info_popup
      id={pool_chip_id(@pool)}
      label={"Why #{@pool.label}'s budget is #{@pool.budget}"}
      trigger_class={chip_class(@pool.state)}
      data-chip-state={@pool.state}
      data-pool={@pool.pool}
    >
      <:trigger>{@pool.chip_label} {@pool.seats}/{budget_text(@pool.budget)}</:trigger>
      <p class="m-0 font-medium text-[var(--text-title)]">
        {@pool.label}: {@pool.seats} of {budget_text(@pool.budget)} seats
      </p>
      <p :if={not @admission.decides} class="m-0 text-[10.5px] text-[var(--text-label)]">
        Shadow: the budget is recorded beside today's decision; today's gate and caps still decide.
      </p>
      <p class="m-0 text-[var(--text-primary)]" data-budget-reason>{@pool.reason}</p>
      <ul
        :if={@pool.windows != []}
        class="m-0 p-0 list-none flex flex-col gap-[6px]"
      >
        <li
          :for={window <- @pool.windows}
          data-window={window.window}
          data-binding={to_string(window.window == @pool.quota_binding)}
          class={[
            "pl-[8px] border-l-2 border-solid",
            if(window.window == @pool.quota_binding,
              do: "border-[var(--arb-attention)]",
              else: "border-[var(--border-default)]"
            )
          ]}
        >
          <.window_numbers window={window} binding?={window.window == @pool.quota_binding} />
        </li>
      </ul>
      <p :if={ceiling_text(@pool.ceiling)} class="m-0" data-ceiling>
        Ceiling: {ceiling_text(@pool.ceiling)}
      </p>
      <p :if={@pool.pending_rise} class="m-0" data-pending-rise>
        Rising to {floor(@pool.pending_rise.raw)} (raw {num(@pool.pending_rise.raw)}) since {clock(
          @pool.pending_rise.since
        )}, once it holds.
      </p>
      <p :if={is_integer(@pool.exempt_budget)} class="m-0" data-exempt-budget>
        Exempt priorities may use up to {@pool.exempt_budget} seats here.
      </p>
      <div class="flex flex-col gap-[3px]" data-seat-holders>
        <p class="m-0 font-medium text-[var(--text-title)]">Holding seats</p>
        <p :if={@pool.holders == []} class="m-0">Nothing holds a seat.</p>
        <ul :if={@pool.holders != []} class="m-0 p-0 list-none flex flex-wrap gap-x-2">
          <li :for={id <- @pool.holders} data-seat-holder={id}>
            <.link navigate={~p"/tasks/#{id}"} class="font-medium hover:underline">{id}</.link>
          </li>
        </ul>
      </div>
      <ul
        :if={@pool.recent_changes != []}
        class="m-0 p-0 list-none flex flex-col gap-[2px] text-[10.5px]"
      >
        <li :for={change <- @pool.recent_changes} data-recent-change>
          {clock(change.at)} {change.from || "–"} → {change.to}
          <span :if={change.reason} class="text-[var(--text-label)]">— {change.reason}</span>
        </li>
      </ul>
      <p
        class="m-0 text-[10.5px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
        data-change-command
      >
        Change the ceiling with `{@pool.change_command}`.
      </p>
    </.info_popup>
    """
  end

  attr :window, :map, required: true
  attr :binding?, :boolean, default: false

  defp window_numbers(assigns) do
    ~H"""
    <span class={@binding? && "text-[var(--text-primary)]"}>
      <span class="font-medium">{@window.window}</span>
      <span
        :if={@binding?}
        class="text-[10px] uppercase tracking-[0.06em] text-[var(--arb-attention)]"
      >
        binds
      </span>
      <span :if={@window.status != "ok"}> —    {@window.status}</span>
      <span :if={@window.status == "ok"}>
        {num(@window.used)} used ({num(@window.used_now)} now), line {num(@window.line_now)} now and {num(
          @window.line_at_h
        )} in {num(@window.horizon_h, 0)}h, {pct(@window.rho)}/seat-h ({@window.rho_source}),
        fits {num(@window.n)} seats, b {num(@window.b)}
      </span>
    </span>
    """
  end

  defp pool_chip_id(pool), do: "pool-chip-#{pool.account}-#{slug(pool.pool)}"

  defp budget_text("unlimited"), do: "∞"
  defp budget_text(budget), do: budget

  defp ceiling_text(%{max_concurrent: mc, share: share}) do
    case Enum.reject([mc && "max_concurrent #{mc}", share && "share #{share}"], &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  defp ceiling_text(_), do: nil

  # ---- a machine ----------------------------------------------------------------

  attr :machine, :map, required: true

  defp node_chip(assigns) do
    assigns = assign(assigns, :state, machine_state(assigns.machine))

    ~H"""
    <.info_popup
      id={"node-chip-#{slug(@machine.name)}"}
      label={"#{@machine.name}: #{@machine.live} running"}
      trigger_class={chip_class(@state)}
      data-chip-state={@state}
    >
      <:trigger>{@machine.name} {machine_fill(@machine)}</:trigger>
      <p class="m-0 font-medium text-[var(--text-title)]">{machine_line(@machine)}</p>
      <p :if={@machine.state != "online"} class="m-0">This machine is {@machine.state}.</p>
      <p class="m-0 text-[10.5px] text-[var(--text-label)] font-[family-name:var(--font-mono)]">
        Change its cap with `arb node set {@machine.name} --max-workers N`.
      </p>
    </.info_popup>
    """
  end

  defp machine_state(%{state: state}) when state != "online", do: "held_hard"
  defp machine_state(%{free: 0}), do: "full"
  defp machine_state(_), do: "free"

  defp machine_fill(%{cap: cap, live: live}) when is_integer(cap), do: "#{live}/#{cap}"
  defp machine_fill(%{live: live}), do: "#{live}"

  defp machine_line(%{cap: cap, live: live, name: name}) when is_integer(cap),
    do: "#{name}: #{live} of #{cap} slots in use"

  defp machine_line(%{live: live, name: name}),
    do: "#{name}: #{live} running; no cap reported"

  # ---- a Ready card's layer --------------------------------------------------------

  attr :budget, :map, required: true, doc: "`CapacityExplainer.budget/2`"

  @doc """
  The cap popup's section for the other layers (DC5): a line per provider pool
  with its reason, per machine, per repo and per fair-share row, from
  `CapacityExplainer.budget/2`. `Shadow` leads it until the budgets decide.
  """
  def budget_lines(assigns) do
    ~H"""
    <div id="board-slot-cap-budgets" class="flex flex-col gap-[4px]" data-mode={@budget.label}>
      <p class="m-0 font-medium text-[var(--text-title)]">
        Provider budgets
        <span
          :if={@budget.shadow?}
          class="ml-1 text-[10px] uppercase tracking-[0.06em] text-[var(--text-label)]"
        >
          Shadow: today's gate and caps still decide
        </span>
      </p>
      <ul class="m-0 p-0 list-none flex flex-col gap-[4px]">
        <li :for={line <- @budget.pools} data-budget-pool data-state={line.state}>
          <span class="text-[var(--text-primary)]">{line.text}</span>
          <span class="block text-[10.5px] text-[var(--text-label)]">{line.reason}</span>
        </li>
        <li :for={line <- @budget.machines} data-budget-machine data-state={line.state}>
          {line.text}
        </li>
        <li :for={line <- @budget.repos} data-budget-repo>{line.text}</li>
        <li :for={line <- @budget.fair_share} data-budget-fair-share>{line.text}</li>
      </ul>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :layer, :map, required: true, doc: "`CapacityExplainer`'s layer for the card"

  @doc """
  The walk's reason for a Ready card, on the card: the layer it waits on or
  the pair it is planned onto. `Shadow walk:` leads it until the walk decides.
  """
  def layer_reason(assigns) do
    ~H"""
    <span
      data-layer-reason={@id}
      data-layer={@layer.layer}
      data-layer-state={@layer.state}
      class="text-[10.5px] leading-[1.5] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
    >
      <span :if={@layer.shadow?}>Shadow walk: </span>{@layer.text}
    </span>
    """
  end

  # ---- shared ----------------------------------------------------------------------

  defp chip_class(state) do
    [
      "px-[6px] py-[1px] rounded-[var(--radius-chip)] border border-solid text-[10.5px] whitespace-nowrap",
      "transition-colors duration-150",
      case state do
        "free" ->
          "border-[var(--border-default)] text-[var(--text-secondary)] hover:text-[var(--text-title)]"

        s when s in ["full", "held_pace"] ->
          "border-[color-mix(in_oklch,var(--arb-attention)_45%,transparent)] text-[var(--arb-attention)]"

        _held_hard ->
          "border-[var(--arb-fail-edge)] text-[var(--arb-fail-text)]"
      end
    ]
  end

  defp slug(text), do: text |> to_string() |> String.replace(~r/[^A-Za-z0-9]+/, "-")

  defp num(value, decimals \\ 2)

  defp num(value, decimals) when is_number(value),
    do: :erlang.float_to_binary(value / 1, decimals: decimals)

  defp num(_, _), do: "–"

  defp pct(value) when is_number(value),
    do: :erlang.float_to_binary(value * 100, decimals: 1) <> "%"

  defp pct(_), do: "–"

  defp clock(%DateTime{} = at), do: Calendar.strftime(at, "%H:%MZ")
  defp clock(_), do: "–"
end
