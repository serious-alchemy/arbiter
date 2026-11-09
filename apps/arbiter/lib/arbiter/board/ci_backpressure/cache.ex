defmodule Arbiter.Board.CiBackpressure.Cache do
  @moduledoc """
  The forge-poll memo behind `Arbiter.Board.CiBackpressure`: one entry per
  `{workspace_id, repo}`, holding the last poll's outcome and when it ran.

  `fetch/4` is what keeps the gate from hammering the forge. The board is read
  by the Autopilot's tick, by every open LiveView and by the status endpoints,
  so a read must never poll by itself:

    * a fresh entry (younger than the interval) is returned as it is;
    * a stale or missing entry is refreshed by **one** poll — a claim under
      `:ets.insert_new/2` makes concurrent readers skip it rather than pile on —
      and, in the default `async` mode, the poll runs in a task under
      `Arbiter.TaskSupervisor`, so a slow forge never blocks a board read. The
      reader gets the previous outcome meanwhile (`:unknown` before the first
      poll lands, and also when the previous reading is older than
      `:max_stale_ms`, #{div(300_000, 1000)}s by default: a reading that old says nothing about the
      queue now);
    * a failed poll is stored too, as `{:error, failures}` — the count of
      consecutive failures — so a forge that is down is asked once per retry
      interval (the shorter of the poll interval and `:retry_ms`), not once
      per read. The gate holds a fresh dispatch for the earlier
      failures and fails open on the `max_failures/0`-th (a forge that stays
      down must not stall a repo), logging a warning each time.

  `note_state/2` is the gate's small memory of what it last decided per key, so
  a hold and its release are each logged once, not on every board read.

  A claim older than #{div(120_000, 1000)}s is taken over, so a poller that was
  killed mid-flight cannot wedge the key. If the table is not up (the cache is
  started by the application) every read is `:unknown`.
  """
  use GenServer

  require Logger

  @table __MODULE__
  @claim_ttl_ms 120_000
  @max_stale_ms 300_000
  @retry_ms 10_000
  @max_failures 3

  @type key :: {String.t() | nil, String.t()}
  @type signal :: %{pending: non_neg_integer(), oldest_at: DateTime.t() | nil}
  @type outcome ::
          {:ok, signal(), DateTime.t()}
          | {:error, pos_integer()}
          | :unknown

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  How many consecutive failed polls it takes before the gate stops holding and
  fails open.
  """
  @spec max_failures() :: pos_integer()
  def max_failures, do: @max_failures

  @doc """
  The outcome for `key`, polling with `poll` (a 0-arity function returning
  `{:ok, signal}` or `{:error, reason}`) when the entry is older than
  `interval_ms`. Options: `:async` (default `true`), `:label`, the text a
  failed poll's warning names, `:retry_ms` (how soon a failed poll is asked
  again, default #{div(10_000, 1000)}s) and `:max_stale_ms` (how old a reading may be and
  still be served while it refreshes).

  Returns `{:ok, signal, at}`, `{:error, failures}` (the last poll failed; this
  is the count of consecutive failures) or `:unknown` (no usable reading).
  """
  @spec fetch(key(), non_neg_integer(), (-> {:ok, signal()} | {:error, term()}), keyword()) ::
          outcome()
  def fetch(key, interval_ms, poll, opts \\ []) do
    now = now_ms()

    entry = :ets.lookup(@table, key)

    if fresh?(entry, now, interval_ms, opts) do
      [{_key, outcome, _at}] = entry
      outcome
    else
      refresh(key, poll, opts, previous(entry, now, opts))
    end
  rescue
    ArgumentError -> :unknown
  end

  @doc """
  Records the state the gate just decided for `key` and says whether it changed:
  `:same`, or `{:changed, previous}` (`nil` the first time). Lets the caller log
  a hold and its release once each.
  """
  @spec note_state(key(), atom()) :: :same | {:changed, atom() | nil}
  def note_state(key, state) do
    slot = {:state, key}

    if :ets.insert_new(@table, {slot, state}) do
      {:changed, nil}
    else
      case :ets.lookup(@table, slot) do
        [{^slot, ^state}] -> :same
        [{^slot, prior}] -> swap_state(slot, prior, state)
        [] -> note_state(key, state)
      end
    end
  rescue
    ArgumentError -> :same
  end

  # Compare-and-swap, so two readers racing on the same change log it once.
  defp swap_state(slot, prior, state) do
    case :ets.select_replace(@table, [{{slot, prior}, [], [{:const, {slot, state}}]}]) do
      1 -> {:changed, prior}
      _ -> :same
    end
  end

  @doc "Drops every entry. Safe to call before the table exists."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp fresh?([{_key, outcome, at}], now, interval_ms, opts),
    do: now - at < freshness(outcome, interval_ms, opts)

  defp fresh?([], _now, _interval_ms, _opts), do: false

  defp freshness({:error, _}, interval_ms, opts),
    do: min(interval_ms, Keyword.get(opts, :retry_ms, @retry_ms))

  defp freshness(_outcome, interval_ms, _opts), do: interval_ms

  # What a reader is handed while a refresh runs. A failed poll stays a failed
  # poll; a good reading only while it is recent enough to mean something.
  defp previous([{_key, {:ok, _, _} = outcome, at}], now, opts) do
    if now - at >= Keyword.get(opts, :max_stale_ms, @max_stale_ms), do: :unknown, else: outcome
  end

  defp previous([{_key, outcome, _at}], _now, _opts), do: outcome
  defp previous([], _now, _opts), do: :unknown

  defp refresh(key, poll, opts, previous) do
    cond do
      not claim(key) -> previous
      Keyword.get(opts, :async, true) -> spawn_poll(key, poll, opts, previous)
      true -> run(key, poll, opts)
    end
  end

  defp spawn_poll(key, poll, opts, previous) do
    case Task.Supervisor.start_child(Arbiter.TaskSupervisor, fn -> run(key, poll, opts) end) do
      {:ok, _pid} ->
        previous

      _ ->
        release(key)
        previous
    end
  end

  defp run(key, poll, opts) do
    outcome = outcome(poll, Keyword.get(opts, :label, inspect(key)), failures(key) + 1)
    :ets.insert(@table, {key, outcome, now_ms()})
    outcome
  after
    release(key)
  end

  # The consecutive failures so far: the count a stored `{:error, n}` carries.
  defp failures(key) do
    case :ets.lookup(@table, key) do
      [{^key, {:error, n}, _at}] -> n
      _ -> 0
    end
  end

  defp outcome(poll, label, failures) do
    case poll.() do
      {:ok, %{pending: pending} = signal} when is_integer(pending) ->
        {:ok, signal, DateTime.utc_now()}

      other ->
        failed(label, other, failures)
    end
  rescue
    e -> failed(label, Exception.message(e), failures)
  catch
    kind, reason -> failed(label, {kind, reason}, failures)
  end

  defp failed(label, reason, failures) do
    if failures >= @max_failures do
      Logger.warning(
        "CiBackpressure: could not read the CI queue for #{label} (#{failures} failed polls " <>
          "in a row), failing open (no hold): #{inspect(reason)}"
      )
    else
      Logger.warning(
        "CiBackpressure: could not read the CI queue for #{label} (failed poll #{failures} of " <>
          "#{@max_failures}), holding new dispatches until it is read or the retries run " <>
          "out: #{inspect(reason)}"
      )
    end

    {:error, failures}
  end

  defp claim(key) do
    now = now_ms()
    lock = {:claim, key}

    cond do
      :ets.insert_new(@table, {lock, now}) ->
        true

      match?([{^lock, at}] when now - at > @claim_ttl_ms, :ets.lookup(@table, lock)) ->
        :ets.insert(@table, {lock, now})
        true

      true ->
        false
    end
  end

  defp release(key), do: :ets.delete(@table, {:claim, key})

  defp now_ms, do: System.monotonic_time(:millisecond)
end
