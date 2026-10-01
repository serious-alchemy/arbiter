defmodule Arbiter.Boot.ResumeGate do
  @moduledoc """
  Holds the board Autopilot's dispatching until the boot reconciler has
  finished re-registering the runs the restart cut off (bd-35gvrj, #169).

  ## The race this closes

  A provider account's `max_concurrent` is enforced from the live worker
  registry (`Arbiter.Accounts.Concurrency.live_count/1` — see its moduledoc),
  and the registry starts empty on every boot. The boot reconciler
  (`Arbiter.Workers.Reconciler.reconcile_resumable_tasks/1`) then re-attaches
  a worker to each `:active` ticket, one `Dispatch.resume/2` at a time.
  Autopilot is a supervised child that starts *before* that sweep, so a pass
  landing in between sees N `:active` tickets and **zero** live workers on the
  account: the headroom reads as the whole cap and a fresh Ready card is
  dispatched on top of the N runs about to be resumed. On 2026-10-01 that put
  a third Claude worker on `claude:default` at `max_concurrent=2`, and the
  over-cap state then survived the next restart too (the reconciler resumes
  every `:active` ticket).

  ## The rule

  Between application start and the end of the boot sweep the gate is
  *closed*, and `Arbiter.Board.Autopilot` plans nothing (no Ready promotion,
  no deferred-resume replay). `sweep/1` runs the sweep and opens the gate when
  it returns — or raises — and tells Autopilot to plan straight away. By then
  every resume that could be started has registered (`Worker.init/1` stamps
  the registry before `Dispatch.resume/2` returns), so the cap check and the
  reconciler read the same registry.

  The gate is closed by a one-shot child placed before Autopilot in
  `Arbiter.Application.children/1`, and only when boot tasks run at all, so
  `mix test` (where nothing reconciles) never sees a closed gate.

  ## Failure modes

    * The sweep raising still opens the gate (`try/after`).
    * The sweep process being *killed* never reaches the `after`, so the close
      carries a deadline (`@max_closed_ms`): a wedged boot cannot leave the
      scheduler off forever. The deadline is far longer than a sweep takes.
    * A non-primary instance runs the same wrapper (its sweeps no-op), so its
      gate opens too.
  """

  @key {__MODULE__, :closed_until}
  @max_closed_ms :timer.minutes(10)

  @doc "A one-shot temporary worker: closes the gate, then `:ignore`s."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @doc false
  @spec start_link(keyword()) :: :ignore
  def start_link(opts \\ []) do
    close(opts)
    :ignore
  end

  @doc "Close the gate. `:max_closed_ms` bounds how long it can stay closed."
  @spec close(keyword()) :: :ok
  def close(opts \\ []) do
    ms = Keyword.get(opts, :max_closed_ms, @max_closed_ms)
    :persistent_term.put(@key, System.monotonic_time(:millisecond) + ms)
  end

  @doc "Open the gate and tell Autopilot (if it is running) to plan now."
  @spec open() :: :ok
  def open do
    _ = :persistent_term.erase(@key)
    Arbiter.Board.Autopilot.resumes_settled()
  end

  @doc "Whether dispatching may proceed. Open unless `close/1` has been called."
  @spec open?() :: boolean()
  def open? do
    case :persistent_term.get(@key, nil) do
      nil -> true
      deadline -> System.monotonic_time(:millisecond) >= deadline
    end
  end

  @doc """
  Run `fun` (the boot reconcile sweeps) and open the gate when it is done,
  however it ends. Returns `fun`'s result.
  """
  @spec sweep((-> result)) :: result when result: term()
  def sweep(fun) when is_function(fun, 0) do
    fun.()
  after
    open()
  end
end
