defmodule Arbiter.NodeAgent.K8s.Informer do
  @moduledoc """
  The pod informer of the Kubernetes in-cluster agent (K3,
  `docs/design/remote-workers.md` k8s §3.3): one watch over the pods of the
  namespace that match a label selector, kept in a `Arbiter.NodeAgent.K8s.PodStore`,
  with the transitions pushed to subscribers.

  ## Loop

  List, then watch from the list's `resourceVersion` with bookmarks. Whatever
  ends the watch, the next one resumes from the **last version the store saw**
  (an event or a bookmark), so a dropped connection loses nothing and replays
  nothing the store already holds. Only a `410 Gone` (the version was compacted
  away) forces a relist, and the relist is diffed against the store, so
  subscribers get the same `added | modified | deleted` transitions the missed
  events would have produced. Errors (API down, 5xx, 401) are retried with
  exponential backoff (`:backoff_ms`) and never crash the informer.

  The list and the watch run in a `Task` linked to the informer; the informer
  itself only folds messages into the store, so `pods/1` and `subscribe/2` stay
  responsive while a watch is blocked on the socket.

  ## Messages to subscribers

    * `{:pod_event, informer, :added | :modified | :deleted, pod}` — in order. For
      `:deleted` the pod is the final object the API sent.
    * `{:pod_synced, informer}` — after every list has been folded in (the initial
      one and each relist): the events before it are the full picture.
    * `{:pod_bookmark, informer, resource_version}` — a bookmark was folded in.

  `subscribe/2` returns the current pods atomically with registration: the
  snapshot, then exactly the transitions after it.
  """

  use GenServer

  alias Arbiter.NodeAgent.K8s.Client
  alias Arbiter.NodeAgent.K8s.PodStore

  require Logger

  @default_backoff {500, 30_000}
  @default_watch_timeout_s 300

  # --- API ----------------------------------------------------------------------

  @doc """
  Options: `:client` (required, a `Client`), `:label_selector`, `:subscriber` (a
  pid, or nil), `:watch_timeout_s`, `:page_limit`, `:backoff_ms` (`{min, max}`),
  `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    gen_opts = if opts[:name], do: [name: opts[:name]], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @doc "The pods currently held."
  @spec pods(GenServer.server()) :: [map()]
  def pods(informer), do: GenServer.call(informer, :pods)

  @doc "Whether the first list has been folded in."
  @spec synced?(GenServer.server()) :: boolean()
  def synced?(informer), do: GenServer.call(informer, :synced?)

  @doc "Blocks until the first list has been folded in."
  @spec await_sync(GenServer.server(), timeout()) :: :ok | {:error, :timeout}
  def await_sync(informer, timeout \\ 5_000) do
    GenServer.call(informer, :await_sync, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  @doc "Subscribes `pid` (default the caller); returns `{:ok, pods}`, the snapshot the later events follow."
  @spec subscribe(GenServer.server(), pid()) :: {:ok, [map()]}
  def subscribe(informer, pid \\ self()), do: GenServer.call(informer, {:subscribe, pid})

  @doc "The subscribed pids."
  @spec subscribers(GenServer.server()) :: [pid()]
  def subscribers(informer), do: GenServer.call(informer, :subscribers)

  # --- server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      client: Keyword.fetch!(opts, :client),
      selector: opts[:label_selector],
      watch_timeout_s: Keyword.get(opts, :watch_timeout_s, @default_watch_timeout_s),
      page_limit: opts[:page_limit],
      backoff: Keyword.get(opts, :backoff_ms, @default_backoff),
      store: PodStore.new(),
      synced?: false,
      sync_waiters: [],
      subscribers: %{},
      task: nil,
      failures: 0,
      events_seen: 0
    }

    state =
      if is_pid(opts[:subscriber]), do: add_subscriber(state, opts[:subscriber]), else: state

    {:ok, state, {:continue, :cycle}}
  end

  @impl true
  def handle_continue(:cycle, state), do: {:noreply, start_cycle(state)}

  @impl true
  def handle_call(:pods, _from, state),
    do: {:reply, Map.values(PodStore.pods(state.store)), state}

  def handle_call(:synced?, _from, state), do: {:reply, state.synced?, state}
  def handle_call(:subscribers, _from, state), do: {:reply, Map.keys(state.subscribers), state}

  def handle_call(:await_sync, from, state) do
    if state.synced?,
      do: {:reply, :ok, state},
      else: {:noreply, %{state | sync_waiters: [from | state.sync_waiters]}}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, {:ok, Map.values(PodStore.pods(state.store))}, add_subscriber(state, pid)}
  end

  @impl true
  def handle_info(:cycle, state), do: {:noreply, start_cycle(state)}

  def handle_info({:watch_event, ref, event}, %{task: %Task{ref: ref}} = state) do
    {:noreply, fold_event(%{state | events_seen: state.events_seen + 1}, event)}
  end

  def handle_info({:watch_event, _stale, _event}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_task(%{state | task: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, finish_task(%{state | task: nil}, {:watch, :error, {:crashed, reason}})}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- the cycle ----------------------------------------------------------------

  defp start_cycle(state) do
    task =
      case PodStore.resource_version(state.store) do
        nil -> start_list(state)
        rv -> start_watch(state, rv)
      end

    %{state | task: task, events_seen: 0}
  end

  defp start_list(state) do
    client = state.client
    opts = [label_selector: state.selector, limit: state.page_limit]
    Task.async(fn -> guarded(:list, fn -> Client.list_pods(client, opts) end) end)
  end

  defp start_watch(state, rv) do
    informer = self()
    client = state.client
    opts = [label_selector: state.selector, timeout_s: state.watch_timeout_s]

    # The task's own ref is not known inside it; events are tagged with the
    # informer's current task ref via a one-shot handshake.
    Task.async(fn ->
      receive do
        {:ref, ref} ->
          guarded(:watch, fn ->
            Client.watch_pods(
              client,
              rv,
              :ok,
              fn event, :ok ->
                send(informer, {:watch_event, ref, event})
                {:cont, :ok}
              end,
              opts
            )
          end)
      end
    end)
    |> tap(fn task -> send(task.pid, {:ref, task.ref}) end)
  end

  defp guarded(kind, fun) do
    case {kind, fun.()} do
      {:list, {:ok, result}} -> {:list, :ok, result}
      {:list, {:error, reason}} -> {:list, :error, reason}
      {:watch, {{:error, reason}, _acc}} -> {:watch, :error, reason}
      {:watch, {outcome, _acc}} -> {:watch, outcome, nil}
    end
  rescue
    exception -> {kind, :error, {:exception, Exception.message(exception)}}
  end

  defp finish_task(state, {:list, :ok, %{items: items, resource_version: rv}}) do
    {transitions, store} = PodStore.replace(state.store, items, rv)
    state = %{state | store: store, failures: 0}
    state = Enum.reduce(transitions, state, &publish/2)
    state = broadcast(state, {:pod_synced, self()})
    state = mark_synced(state)
    start_next(state, 0)
  end

  defp finish_task(state, {:list, :error, reason}) do
    Logger.warning("k8s informer: list failed: #{inspect(reason)}")
    retry(state)
  end

  defp finish_task(state, {:watch, :gone, _}) do
    Logger.info("k8s informer: resourceVersion expired (410), relisting")
    state = %{state | store: PodStore.expire(state.store)}
    if state.events_seen > 0, do: start_next(%{state | failures: 0}, 0), else: retry(state)
  end

  defp finish_task(state, {:watch, outcome, _}) when outcome in [:closed, :halted] do
    # A watch that delivered anything made progress: reconnect at once. One that
    # delivered nothing (the server hanging up immediately) backs off.
    if state.events_seen > 0, do: start_next(%{state | failures: 0}, 0), else: retry(state)
  end

  defp finish_task(state, {:watch, :error, reason}) do
    Logger.warning("k8s informer: watch failed: #{inspect(reason)}")
    state = if state.events_seen > 0, do: %{state | failures: 0}, else: state
    retry(state)
  end

  defp retry(state) do
    failures = state.failures + 1
    {min, max} = state.backoff
    delay = min(max, min * Integer.pow(2, failures - 1))
    start_next(%{state | failures: failures}, delay)
  end

  defp start_next(state, 0) do
    send(self(), :cycle)
    state
  end

  defp start_next(state, delay) do
    Process.send_after(self(), :cycle, delay)
    state
  end

  # --- folding ------------------------------------------------------------------

  defp fold_event(state, {:bookmark, object}) do
    rv = get_in(object, ["metadata", "resourceVersion"])
    state = %{state | store: PodStore.bookmark(state.store, rv)}
    broadcast(state, {:pod_bookmark, self(), rv})
  end

  defp fold_event(state, {type, pod}) do
    {transitions, store} = PodStore.apply_event(state.store, type, pod)
    Enum.reduce(transitions, %{state | store: store}, &publish/2)
  end

  defp publish({type, pod}, state), do: broadcast(state, {:pod_event, self(), type, pod})

  defp broadcast(state, message) do
    for pid <- Map.keys(state.subscribers), do: send(pid, message)
    state
  end

  defp add_subscriber(state, pid) do
    if Map.has_key?(state.subscribers, pid),
      do: state,
      else: %{state | subscribers: Map.put(state.subscribers, pid, Process.monitor(pid))}
  end

  defp mark_synced(%{synced?: true} = state), do: state

  defp mark_synced(state) do
    for from <- state.sync_waiters, do: GenServer.reply(from, :ok)
    %{state | synced?: true, sync_waiters: []}
  end
end
