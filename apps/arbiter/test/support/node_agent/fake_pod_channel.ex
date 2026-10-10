defmodule Arbiter.Test.FakePodChannel do
  @moduledoc """
  Stands in for `Arbiter.NodeAgent.PodChannel.Runs` in the controller tests (K5): the
  same three calls with the server first, recording what the controller asked and
  handing out a nonce. The real table is covered by `PodChannelTest`; here the
  question is only *when* the controller registers, binds and releases a run.
  """
  use Agent

  def start_link(opts \\ []), do: Agent.start_link(fn -> %{calls: [], fail: opts[:fail]} end)

  def child_spec(opts), do: %{id: make_ref(), start: {__MODULE__, :start_link, [opts]}}

  def register(server, spec, deadline) do
    Agent.get_and_update(server, fn state ->
      state = %{state | calls: [{:register, spec.run, deadline} | state.calls]}

      case state.fail do
        nil -> {{:ok, String.duplicate("n", 43)}, state}
        reason -> {{:error, reason}, state}
      end
    end)
  end

  def bind_pod_ip(server, run, ip) do
    Agent.update(server, &%{&1 | calls: [{:bind, run, ip} | &1.calls]})
  end

  def release(server, run), do: Agent.update(server, &%{&1 | calls: [{:release, run} | &1.calls]})

  @doc "The calls so far, oldest first."
  def calls(server), do: server |> Agent.get(& &1.calls) |> Enum.reverse()
end
