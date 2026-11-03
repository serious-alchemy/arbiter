defmodule Arbiter.Worker.Image.LocalRuns do
  @moduledoc """
  The local runs that are using a published image (SI-L, bd-4cq0qt): the "live runs"
  the local image store's GC (`Arbiter.NodeAgent.ImageGC`, see
  `Arbiter.Worker.Image.LocalPublished.gc_spec/1`) must never take an image from.

  `track/3` records a run id against its owner (the worker process the run lives and
  dies with). The run is live while that process is, so a worker killed without a
  teardown does not pin an image forever.
  """

  use GenServer

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, name: name(opts))

  @doc "Note that run `run` is live while `owner` is. `:ok` (also with no tracker running)."
  @spec track(String.t(), pid() | nil, keyword()) :: :ok
  def track(run, owner, opts \\ [])

  def track(run, owner, opts) when is_binary(run) and is_pid(owner) do
    GenServer.call(name(opts), {:track, run, owner})
  catch
    :exit, _ -> :ok
  end

  def track(_run, _owner, _opts), do: :ok

  @doc "The run ids that are live now."
  @spec live(keyword()) :: [String.t()]
  def live(opts \\ []) do
    GenServer.call(name(opts), :live)
  catch
    :exit, _ -> []
  end

  @impl true
  def init(:ok), do: {:ok, %{refs: %{}}}

  @impl true
  def handle_call({:track, run, owner}, _from, state) do
    ref = Process.monitor(owner)
    {:reply, :ok, %{state | refs: Map.put(state.refs, ref, run)}}
  end

  def handle_call(:live, _from, state),
    do: {:reply, state.refs |> Map.values() |> Enum.uniq(), state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | refs: Map.delete(state.refs, ref)}}

  def handle_info(_other, state), do: {:noreply, state}

  defp name(opts), do: Keyword.get(opts, :name, __MODULE__)
end
