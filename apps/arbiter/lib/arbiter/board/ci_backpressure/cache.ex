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
      poll lands);
    * a failed poll is stored too, so a forge that is down is asked once per
      interval, not once per read. It reads `:unknown`, which the gate treats
      as "not saturated" (fail open), with a logged warning.

  A claim older than #{div(120_000, 1000)}s is taken over, so a poller that was
  killed mid-flight cannot wedge the key. If the table is not up (the cache is
  started by the application) every read is `:unknown`.
  """
  use GenServer

  require Logger

  @table __MODULE__
  @claim_ttl_ms 120_000

  @type key :: {String.t() | nil, String.t()}
  @type signal :: %{pending: non_neg_integer(), oldest_at: DateTime.t() | nil}
  @type outcome :: {:ok, signal(), DateTime.t()} | :unknown

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  The outcome for `key`, polling with `poll` (a 0-arity function returning
  `{:ok, signal}` or `{:error, reason}`) when the entry is older than
  `interval_ms`. Options: `:async` (default `true`) and `:label`, the text a
  failed poll's warning names.
  """
  @spec fetch(key(), non_neg_integer(), (-> {:ok, signal()} | {:error, term()}), keyword()) ::
          outcome()
  def fetch(key, interval_ms, poll, opts \\ []) do
    now = now_ms()

    case :ets.lookup(@table, key) do
      [{^key, outcome, at}] when now - at < interval_ms ->
        outcome

      entry ->
        previous = previous(entry)
        refresh(key, poll, opts, previous)
    end
  rescue
    ArgumentError -> :unknown
  end

  @doc "Drops every entry. Safe to call before the table exists."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp previous([{_key, outcome, _at}]), do: outcome
  defp previous([]), do: :unknown

  defp refresh(key, poll, opts, previous) do
    if claim(key) do
      if Keyword.get(opts, :async, true) do
        case Task.Supervisor.start_child(Arbiter.TaskSupervisor, fn -> run(key, poll, opts) end) do
          {:ok, _pid} ->
            previous

          _ ->
            release(key)
            previous
        end
      else
        run(key, poll, opts)
      end
    else
      previous
    end
  end

  defp run(key, poll, opts) do
    outcome = outcome(poll, Keyword.get(opts, :label, inspect(key)))
    :ets.insert(@table, {key, outcome, now_ms()})
    outcome
  after
    release(key)
  end

  defp outcome(poll, label) do
    case poll.() do
      {:ok, %{pending: pending} = signal} when is_integer(pending) ->
        {:ok, signal, DateTime.utc_now()}

      other ->
        fail_open(label, other)
    end
  rescue
    e -> fail_open(label, Exception.message(e))
  catch
    kind, reason -> fail_open(label, {kind, reason})
  end

  defp fail_open(label, reason) do
    Logger.warning(
      "CiBackpressure: could not read the CI queue for #{label}, failing open " <>
        "(no hold): #{inspect(reason)}"
    )

    :unknown
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
