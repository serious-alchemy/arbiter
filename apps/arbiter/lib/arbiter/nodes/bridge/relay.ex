defmodule Arbiter.Nodes.Bridge.Relay do
  @moduledoc """
  What the two ends of the bridge multiplexer have in common
  (`docs/design/remote-workers.md` §8): a `Arbiter.Nodes.Bridge.Core` (the
  protocol), the `Arbiter.Nodes.Bridge.Stream` process that owns each stream's
  local socket, and the code that carries out the core's effects. The primary's
  `Arbiter.Nodes.Bridge` and the agent's `Arbiter.NodeAgent.Bridge` are each a
  process that owns one of these and feeds it what arrives.

  `push` is `fun(event, payload)`, how this end sends on the node channel
  (`bridge.data` carries `{:binary, frame}`). Every function returns
  `{:cont, relay}`, or `{:stop, reason, relay}` when the peer broke the protocol
  and the channel must go.
  """

  alias Arbiter.Nodes.Bridge.{Core, Stream}

  require Logger

  defstruct [:core, :push, :label, pids: %{}]

  @type t :: %__MODULE__{}
  @type result :: {:cont, t()} | {:stop, term(), t()}

  @spec new(map(), (String.t(), term() -> term()), term()) :: t()
  def new(limits, push, label \\ nil),
    do: %__MODULE__{core: Core.new(limits), push: push, label: label}

  @doc "Where this end sends from now on (the channel it is attached to changed)."
  @spec put_push(t(), (String.t(), term() -> term())) :: t()
  def put_push(%__MODULE__{} = relay, push), do: %{relay | push: push}

  @spec info(t()) :: map()
  def info(%__MODULE__{core: core}),
    do: %{streams: Core.stream_ids(core), inflight: Core.inflight(core)}

  @doc "The peer's event (`bridge.data`, `.credit`, `.recv`, `.close`, `.reset`)."
  @spec remote(t(), String.t(), term()) :: result()
  def remote(%__MODULE__{} = relay, event, payload) do
    {core, effects} = Core.remote(relay.core, event, payload)
    perform(%{relay | core: core}, effects)
  end

  @doc "This end opens `id` (a connection it accepted) on `stream` and announces it."
  @spec open_local(t(), non_neg_integer(), String.t(), String.t(), pid()) ::
          {:ok, t()} | {:error, atom()}
  def open_local(%__MODULE__{} = relay, id, run, name, pid) do
    with {:ok, core, effects} <- Core.open_local(relay.core, id, run, name) do
      {:cont, relay} = perform(%{relay | core: core, pids: Map.put(relay.pids, id, pid)}, effects)
      {:ok, relay}
    end
  end

  @doc "The peer opened `id` (the caller authorized it) on `pid`."
  @spec open_remote(t(), non_neg_integer(), String.t(), String.t()) ::
          {:ok, t()} | {:error, atom()}
  def open_remote(%__MODULE__{} = relay, id, run, name) do
    with {:ok, core, _effects} <- Core.open_remote(relay.core, id, run, name),
         do: {:ok, %{relay | core: core}}
  end

  @doc "The stream process for a stream `open_remote/4` accepted."
  @spec attach_stream(t(), non_neg_integer(), pid()) :: t()
  def attach_stream(%__MODULE__{} = relay, id, pid),
    do: %{relay | pids: Map.put(relay.pids, id, pid)}

  @doc "End `id` from this end, telling the peer."
  @spec reset(t(), non_neg_integer(), atom()) :: result()
  def reset(%__MODULE__{} = relay, id, reason) do
    {core, effects} = Core.reset(relay.core, id, reason)
    perform(%{relay | core: core}, effects)
  end

  @doc "End every stream of `run` from this end."
  @spec reset_run(t(), String.t(), atom()) :: result()
  def reset_run(%__MODULE__{} = relay, run, reason) do
    Enum.reduce_while(Core.run_streams(relay.core, run), {:cont, relay}, fn id, {:cont, acc} ->
      case reset(acc, id, reason) do
        {:cont, _} = ok -> {:cont, ok}
        stop -> {:halt, stop}
      end
    end)
  end

  @doc "An event a stream process sent its owner (`{:bridge_stream, id, event}`)."
  @spec stream_event(t(), non_neg_integer(), term()) :: result()
  def stream_event(%__MODULE__{} = relay, id, {:data, bytes}) do
    {core, effects} = Core.local_data(relay.core, id, bytes)
    perform(%{relay | core: core}, effects)
  end

  def stream_event(%__MODULE__{} = relay, id, :eof) do
    {core, effects} = Core.local_eof(relay.core, id)
    perform(%{relay | core: core}, effects)
  end

  def stream_event(%__MODULE__{} = relay, id, {:wrote, n}) do
    {core, effects} = Core.local_wrote(relay.core, id, n)
    perform(%{relay | core: core}, effects)
  end

  def stream_event(%__MODULE__{} = relay, id, {:failed, reason}) do
    Logger.debug("bridge: stream #{id} failed: #{inspect(reason)}")
    reset(relay, id, :stream_failed)
  end

  @doc """
  A stream process exited. Its last words came first; one still in the table
  died without saying so. `:error` when `pid` is not one of ours.
  """
  @spec stream_down(t(), pid(), term()) :: result() | :error
  def stream_down(%__MODULE__{} = relay, pid, reason) do
    case Enum.find(relay.pids, fn {_id, p} -> p == pid end) do
      {id, _} -> reset(%{relay | pids: Map.delete(relay.pids, id)}, id, exit_reason(reason))
      nil -> :error
    end
  end

  @doc "Stop every stream process (the channel or this end is going away)."
  @spec stop_all(t()) :: :ok
  def stop_all(%__MODULE__{pids: pids}) do
    Enum.each(pids, fn {_id, pid} -> Stream.stop(pid) end)
  end

  @doc "Forget every stream, stopping its process; the limits and the sender are kept."
  @spec clear(t(), map()) :: t()
  def clear(%__MODULE__{} = relay, limits) do
    stop_all(relay)
    %{relay | core: Core.new(limits), pids: %{}}
  end

  # ---- effects --------------------------------------------------------------

  defp perform(relay, effects) do
    Enum.reduce_while(effects, {:cont, relay}, fn effect, {:cont, relay} ->
      case effect(relay, effect) do
        {:cont, _} = ok -> {:cont, ok}
        {:stop, _, _} = stop -> {:halt, stop}
      end
    end)
  end

  defp effect(relay, {:push, event, payload}) do
    relay.push.(event, payload)
    {:cont, relay}
  end

  defp effect(relay, {:stream, id, :write, bytes}),
    do: with_stream(relay, id, &Stream.write(&1, bytes))

  defp effect(relay, {:stream, id, :rearm}), do: with_stream(relay, id, &Stream.rearm/1)

  defp effect(relay, {:stream, id, :shutdown_write}),
    do: with_stream(relay, id, &Stream.shutdown_write/1)

  defp effect(relay, {:stream, id, :stop}) do
    {:cont, relay} = with_stream(relay, id, &Stream.stop/1)
    {:cont, %{relay | pids: Map.delete(relay.pids, id)}}
  end

  defp effect(relay, {:violation, reason}) do
    Logger.warning("bridge: #{inspect(relay.label)} broke the protocol: #{inspect(reason)}")
    {:stop, {:shutdown, {:violation, reason}}, relay}
  end

  defp with_stream(relay, id, fun) do
    case relay.pids do
      %{^id => pid} -> fun.(pid)
      _ -> :ok
    end

    {:cont, relay}
  end

  defp exit_reason(:normal), do: :stream_closed
  defp exit_reason(_), do: :stream_crashed
end
