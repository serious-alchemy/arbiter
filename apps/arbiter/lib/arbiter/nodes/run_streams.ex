defmodule Arbiter.Nodes.RunStreams do
  @moduledoc """
  The primary's table of runs placed on one node (`docs/design/remote-workers.md`
  §7.2, §10.2): what `Arbiter.Nodes.Session` keeps between channel connections so
  a blip loses nothing. Pure: every function takes the table and returns the new
  table plus **effects** for the session to carry out.

      {:reply, from, value}        answer a deferred `assign`
      {:send, pid, message}        a Port-shaped message to the run's owner (the Worker)
      {:push, event, payload}      a channel push to the node

  ## stdout

  The node sends `StdoutFrame`s with the offset of their first byte. The table
  keeps the next offset it expects per run: a frame wholly before it is a replay
  (dropped, and `ack`ed again so the node's window moves), one that overlaps is
  trimmed, one that starts beyond it is a gap (ignored; the node resends from
  its last ack, which is the last thing we acknowledged). New bytes are cut into
  lines exactly as a `{:line, 65_536}` port would (`Arbiter.Nodes.LineSplitter`)
  and sent to the owner as `{handle, {:data, {:eol | :noeol, line}}}`; the ack is
  cumulative.

  ## The end

  `exit` carries the total stdout `size`. The owner is told the run ended
  (`{handle, {:outcome, %{oom?, exit_code, cancelled?}}}` then `{handle,
  {:exit_status, code}}`) only once every one of those bytes has been delivered,
  so the tail of the output is never lost to an exit that overtook it, and the
  node is then told (`exit_ack`) it may forget the run. The held partial line is
  flushed first.
  """

  alias Arbiter.Nodes.LineSplitter

  defstruct streams: %{}

  @type t :: %__MODULE__{}
  @type effect ::
          {:reply, GenServer.from(), term()}
          | {:send, pid(), term()}
          | {:push, String.t(), map()}

  @doc """
  Register run `run` placed with `handle`; `owner` receives its messages, `waiter`
  the answer to `assign`. `bridges` is `%{name => primary socket path}`, the
  per-run sockets the node may open streams to (`bridge_target/3`).
  """
  @spec open(t(), String.t(), term(), pid(), GenServer.from() | nil, %{String.t() => Path.t()}) ::
          t()
  def open(%__MODULE__{} = table, run, handle, owner, waiter, bridges \\ %{}) do
    stream = %{
      handle: handle,
      owner: owner,
      waiter: waiter,
      bridges: bridges,
      state: :assigned,
      next: 0,
      partial: "",
      exit: nil,
      cancel?: false,
      outcome: nil
    }

    put_in(table.streams[run], stream)
  end

  @spec fetch(t(), String.t()) :: {:ok, map()} | :error
  def fetch(%__MODULE__{streams: streams}, run), do: Map.fetch(streams, run)

  @doc """
  The primary's own socket for bridge `name` of `run`: only for a run the node
  holds that has not ended, and only for a name the run's spec declared.
  """
  @spec bridge_target(t(), String.t(), String.t()) :: {:ok, Path.t()} | {:error, atom()}
  def bridge_target(%__MODULE__{streams: streams}, run, name) do
    case streams do
      %{^run => %{state: :done}} -> {:error, :run_ended}
      %{^run => %{bridges: %{^name => path}}} -> {:ok, path}
      %{^run => _} -> {:error, :unknown_bridge}
      _ -> {:error, :unknown_run}
    end
  end

  @spec run_for_handle(t(), term()) :: String.t() | nil
  def run_for_handle(%__MODULE__{streams: streams}, handle) do
    Enum.find_value(streams, fn {run, %{handle: h}} -> if h == handle, do: run end)
  end

  @doc "Runs the node still has (not yet ended)."
  @spec live(t()) :: [String.t()]
  def live(%__MODULE__{streams: streams}),
    do: for({run, %{state: state}} <- streams, state != :done, do: run) |> Enum.sort()

  @spec ready(t(), String.t()) :: {t(), [effect()]}
  def ready(table, run) do
    update(table, run, fn
      %{state: :assigned, waiter: waiter, handle: handle} = s ->
        {%{s | state: :ready, waiter: nil}, reply(waiter, {:ok, handle})}

      s ->
        {s, []}
    end)
  end

  @doc "The node refused the run: answer the waiter and drop the stream."
  @spec refused(t(), String.t(), map()) :: {t(), [effect()]}
  def refused(table, run, payload) do
    case Map.fetch(table.streams, run) do
      {:ok, %{waiter: waiter}} ->
        error = {:error, {:refused, payload["reason"], payload["detail"]}}
        {%{table | streams: Map.delete(table.streams, run)}, reply(waiter, error)}

      :error ->
        {table, []}
    end
  end

  @spec data(t(), String.t(), non_neg_integer(), binary()) :: {t(), [effect()]}
  def data(table, run, offset, bytes) do
    update(table, run, fn
      %{state: :done} = s ->
        {s, []}

      %{next: next} = s when offset > next ->
        # A gap: nothing is acknowledged past `next`, so the node replays it.
        {s, []}

      %{next: next} = s ->
        skip = next - offset

        if skip >= byte_size(bytes) do
          {s, [ack(run, next)]}
        else
          fresh = binary_part(bytes, skip, byte_size(bytes) - skip)
          {frames, partial} = LineSplitter.split(s.partial, fresh)
          s = %{s | next: next + byte_size(fresh), partial: partial}

          sends = for frame <- frames, do: {:send, s.owner, {s.handle, {:data, frame}}}
          {s, sends ++ [ack(run, s.next)]}
        end
    end)
    |> finish_if_complete(run)
  end

  @spec exit(t(), String.t(), map()) :: {t(), [effect()]}
  def exit(table, run, payload) do
    update(table, run, fn
      %{state: :done} = s -> {s, [{:push, "exit_ack", %{"run" => run}}]}
      s -> {%{s | exit: payload}, []}
    end)
    |> finish_if_complete(run)
  end

  @doc "Ask the node to stop `run`; remembered so a reconnect asks again."
  @spec cancel(t(), String.t(), String.t()) :: {t(), [effect()]}
  def cancel(table, run, reason) do
    update(table, run, fn
      %{state: :done} = s -> {s, []}
      s -> {%{s | cancel?: true}, [{:push, "cancel", %{"run" => run, "reason" => reason}}]}
    end)
  end

  @doc "A new connection: re-ask for every cancel the node may not have heard."
  @spec reattach(t()) :: [effect()]
  def reattach(%__MODULE__{streams: streams}) do
    for {run, %{cancel?: true, state: state}} <- streams,
        state != :done,
        do: {:push, "cancel", %{"run" => run, "reason" => "resend"}}
  end

  @doc "The node is gone for good: every live run ends, flagged `node_lost?`."
  @spec node_lost(t()) :: {t(), [effect()]}
  def node_lost(%__MODULE__{} = table), do: end_lost(table, fn _run -> true end)

  @doc """
  A node's `hello` lists the runs it has. A run we hold as live that the node
  does not list is gone (the agent restarted and lost it): it ends for its owner,
  flagged `node_lost?`, rather than leave a Worker waiting for output that will
  not come.
  """
  @spec reconcile(t(), [String.t()]) :: {t(), [effect()]}
  def reconcile(%__MODULE__{} = table, present), do: end_lost(table, &(&1 not in present))

  defp end_lost(%__MODULE__{streams: streams} = table, pick) do
    Enum.reduce(streams, {table, []}, fn
      {_run, %{state: :done}}, acc ->
        acc

      {run, %{waiter: waiter}}, {t, effects} when not is_nil(waiter) ->
        if pick.(run),
          do:
            {%{t | streams: Map.delete(t.streams, run)},
             effects ++ reply(waiter, {:error, :node_lost})},
          else: {t, effects}

      {run, s}, {t, effects} ->
        if pick.(run) do
          outcome = %{oom?: false, exit_code: 255, cancelled?: false, node_lost?: true}

          {put_in(t.streams[run], %{s | state: :done, outcome: outcome}),
           effects ++ ended(s, outcome, 255)}
        else
          {t, effects}
        end
    end)
  end

  @doc "The recorded outcome of an ended run."
  @spec outcome(t(), String.t()) :: {:ok, map()} | :pending | :error
  def outcome(%__MODULE__{streams: streams}, run) do
    case Map.fetch(streams, run) do
      {:ok, %{outcome: %{} = outcome}} -> {:ok, outcome}
      {:ok, _} -> :pending
      :error -> :error
    end
  end

  @doc "Forget `run` (its owner went away or released it)."
  @spec drop(t(), String.t()) :: t()
  def drop(table, run), do: %{table | streams: Map.delete(table.streams, run)}

  @doc """
  The owner is leaving `run` to the node on purpose (the primary is shutting down):
  nothing is sent to it from now on, and its death no longer cancels the run.
  """
  @spec abandon(t(), String.t()) :: t()
  def abandon(table, run) do
    {table, []} = update(table, run, fn stream -> {%{stream | owner: nil}, []} end)
    table
  end

  @doc "Every run owned by `owner`."
  @spec owned_by(t(), pid()) :: [String.t()]
  def owned_by(%__MODULE__{streams: streams}, owner),
    do: for({run, %{owner: ^owner}} <- streams, do: run)

  # -- internals ----------------------------------------------------------------------

  defp finish_if_complete({table, effects}, run) do
    case Map.fetch(table.streams, run) do
      {:ok, %{exit: %{"size" => size} = exit, next: next, state: state} = s}
      when state != :done and next >= size ->
        status = exit["status"]

        outcome = %{
          oom?: exit["oom"] == true,
          exit_code: status,
          cancelled?: exit["cancelled"] == true,
          node_lost?: false
        }

        flushed =
          for frame <- LineSplitter.flush(s.partial),
              do: {:send, s.owner, {s.handle, {:data, frame}}}

        s = %{s | state: :done, partial: "", outcome: outcome}

        {put_in(table.streams[run], s),
         effects ++ flushed ++ ended(s, outcome, status) ++ [{:push, "exit_ack", %{"run" => run}}]}

      _ ->
        {table, effects}
    end
  end

  defp ended(%{owner: owner, handle: handle}, outcome, status),
    do: [
      {:send, owner, {handle, {:outcome, outcome}}},
      {:send, owner, {handle, {:exit_status, status}}}
    ]

  defp ack(run, offset), do: {:push, "ack", %{"run" => run, "offset" => offset}}

  defp reply(nil, _value), do: []
  defp reply(from, value), do: [{:reply, from, value}]

  defp update(table, run, fun) do
    case Map.fetch(table.streams, run) do
      {:ok, stream} ->
        {stream, effects} = fun.(stream)
        {put_in(table.streams[run], stream), effects}

      :error ->
        {table, []}
    end
  end
end
