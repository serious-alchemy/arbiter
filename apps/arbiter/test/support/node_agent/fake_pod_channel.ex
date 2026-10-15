defmodule Arbiter.Test.FakePodChannel do
  @moduledoc """
  Stands in for `Arbiter.NodeAgent.PodChannel.Runs` in the controller tests (K5, K15): the
  same calls with the server first, recording what the controller asked and handing out a
  nonce. The real table is covered by `PodChannelTest` and `RunsTest`; here the question is
  only *when* the controller registers, adopts, binds and releases a run.
  """
  use Agent

  def start_link(opts \\ []),
    do: Agent.start_link(fn -> %{calls: [], fail: opts[:fail], known: MapSet.new()} end)

  def child_spec(opts), do: %{id: make_ref(), start: {__MODULE__, :start_link, [opts]}}

  def register(server, spec, deadline) do
    Agent.get_and_update(server, fn state ->
      state = %{state | calls: [{:register, spec.run, deadline} | state.calls]}

      case state.fail do
        nil -> {{:ok, String.duplicate("n", 43)}, know(state, spec.run)}
        reason -> {{:error, reason}, state}
      end
    end)
  end

  @doc "The public record a restarted controller adopts the run from (opaque to the controller)."
  def channel_record(_server, run), do: {:ok, %{"fake" => "record", "run" => run}}

  def adopt(server, run, record) do
    Agent.get_and_update(server, fn state ->
      state = %{state | calls: [{:adopt, run, record} | state.calls]}

      case Map.get(state, :adopt_result, {:ok, :adopted}) do
        {:ok, _} = ok -> {ok, know(state, run)}
        error -> {error, state}
      end
    end)
  end

  @doc "Makes the next `adopt/3` calls answer `result`."
  def adopt_answers(server, result), do: Agent.update(server, &Map.put(&1, :adopt_result, result))

  def bind_pod_ip(server, run, ip) do
    Agent.update(server, &%{&1 | calls: [{:bind, run, ip} | &1.calls]})
  end

  def release(server, run) do
    Agent.update(server, fn state ->
      %{state | calls: [{:release, run} | state.calls], known: MapSet.delete(state.known, run)}
    end)
  end

  @doc "The runs the table holds."
  def live_runs(server), do: server |> Agent.get(& &1.known) |> MapSet.to_list()

  @doc "The table loses `run` (its process crashed and came back empty)."
  def forget(server, run),
    do: Agent.update(server, &%{&1 | known: MapSet.delete(&1.known, run)})

  @doc "The calls so far, oldest first."
  def calls(server), do: server |> Agent.get(& &1.calls) |> Enum.reverse()

  defp know(state, run), do: %{state | known: MapSet.put(state.known, run)}
end
