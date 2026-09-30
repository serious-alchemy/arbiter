defmodule Arbiter.Test.StubFixPassDispatcher do
  @moduledoc """
  In-memory `Arbiter.Workflows.MergeQueue.FixPassDispatcher` stub for tests.

  Backed by a single named `Agent` so it can be observed from the Watchdog's poll
  process (a process-dictionary stub wouldn't survive the cross-process hop).
  Records every `dispatch/1` call (assert via `call_count/0` / `last_args/0`) and
  returns `{:ok, %{stub: true}}` so the Watchdog treats the dispatch as succeeded.
  """

  @behaviour Arbiter.Workflows.MergeQueue.FixPassDispatcher

  @name __MODULE__.Store

  def reset do
    ensure_started()
    Agent.update(@name, fn _ -> %{calls: [], reply: nil} end)
    :ok
  end

  @doc "Make every following `dispatch/1` return `reply` (default: `{:ok, %{stub: true}}`)."
  def reply_with(reply) do
    ensure_started()
    Agent.update(@name, &Map.put(&1, :reply, reply))
  end

  @doc "How many times `dispatch/1` was called."
  def call_count do
    ensure_started()
    Agent.get(@name, fn s -> length(s.calls) end)
  end

  @doc "The args of the most recent `dispatch/1` call, or nil."
  def last_args do
    ensure_started()
    Agent.get(@name, fn s -> List.first(s.calls) end)
  end

  @impl true
  def dispatch(args) do
    ensure_started()

    Agent.get_and_update(@name, fn s ->
      {s[:reply] || {:ok, %{stub: true}}, %{s | calls: [args | s.calls]}}
    end)
  end

  defp ensure_started do
    case Process.whereis(@name) do
      nil ->
        case Agent.start(fn -> %{calls: []} end, name: @name) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _pid ->
        :ok
    end
  end
end
