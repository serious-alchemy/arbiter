defmodule Arbiter.NodeAgent.K8s.ConfigLoader do
  @moduledoc """
  Keeps the controller's operator config current
  (`docs/design/remote-workers.md` K§4.1): the ConfigMap `arbiter-controller-config`
  is mounted at `/etc/arb/config/controller.yaml` and re-read every 30 s (the kubelet
  propagates an edit within about a minute; reading a file needs no RBAC).

  The rule is **keep the last good config**: a file that fails
  `Arbiter.NodeAgent.K8s.ControllerConfig` leaves `current/1` as it was and raises
  `degraded: bad_config` (`degraded/1`, what `hb` carries) until a later read
  succeeds. A bad file at *start*, before any good one, leaves no config
  (`{:error, :no_config}`): the controller then refuses to assign rather than guess
  at a ceiling. A **missing** file is the defaults, since an install that never
  edited its ConfigMap has nothing to say.

  Subscribers (`:notify`, a pid or list, and `subscribe/2`) get `{:controller_config, loader, config}` when a
  new good config differs from the one held and `{:controller_degraded, loader,
  words}` when the degraded list changes.

  Options: `:path` (default `/etc/arb/config/controller.yaml`), `:interval_ms`
  (default 30 000; `nil` for no polling, tests call `reload/1`), `:notify`, `:name`.
  """

  use GenServer

  alias Arbiter.NodeAgent.K8s.ControllerConfig

  require Logger

  @default_path "/etc/arb/config/controller.yaml"
  @default_interval_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    gen_opts = if opts[:name], do: [name: opts[:name]], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "The last good config, or `{:error, :no_config}` when none has ever loaded."
  @spec current(GenServer.server()) :: {:ok, ControllerConfig.t()} | {:error, :no_config}
  def current(loader), do: GenServer.call(loader, :current)

  @doc "`[\"bad_config\"]` while the file on disk is invalid, else `[]`."
  @spec degraded(GenServer.server()) :: [String.t()]
  def degraded(loader), do: GenServer.call(loader, :degraded)

  @doc "Also tell `pid` about config and degraded changes."
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(loader, pid \\ self()), do: GenServer.call(loader, {:subscribe, pid})

  @doc "Re-read the file now; `:ok`, or the validation error (the last good config is kept)."
  @spec reload(GenServer.server()) :: :ok | {:error, term()}
  def reload(loader), do: GenServer.call(loader, :reload)

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      path: Keyword.get(opts, :path, @default_path),
      interval: Keyword.get(opts, :interval_ms, @default_interval_ms),
      subscribers: opts[:notify] |> List.wrap() |> Enum.filter(&is_pid/1),
      config: nil,
      degraded: [],
      announce?: false
    }

    # The first read is the starting point, not a change: nobody is told about it.
    {_result, state} = load(state)
    {:ok, schedule(%{state | announce?: true})}
  end

  @impl true
  def handle_call(:current, _from, %{config: nil} = state),
    do: {:reply, {:error, :no_config}, state}

  def handle_call(:current, _from, state), do: {:reply, {:ok, state.config}, state}
  def handle_call(:degraded, _from, state), do: {:reply, state.degraded, state}

  def handle_call({:subscribe, pid}, _from, state),
    do: {:reply, :ok, %{state | subscribers: Enum.uniq([pid | state.subscribers])}}

  def handle_call(:reload, _from, state) do
    {result, state} = load(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:poll, state) do
    {_result, state} = load(state)
    {:noreply, schedule(state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- internals ----------------------------------------------------------------

  defp schedule(%{interval: ms} = state) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :poll, ms)
    state
  end

  defp schedule(state), do: state

  defp load(state) do
    case read(state.path) do
      {:ok, text} -> text |> ControllerConfig.parse() |> loaded(state)
      {:error, reason} -> failed(state, reason)
    end
  end

  # No file at all: nothing was configured, the defaults apply.
  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, :enoent} -> {:ok, "{}"}
      {:error, posix} -> {:error, {:bad_config, {:read, posix}}}
    end
  end

  defp loaded({:ok, config}, state) do
    if config != state.config, do: tell(state, {:controller_config, self(), config})
    {:ok, set_degraded(%{state | config: config}, [])}
  end

  defp loaded({:error, reason}, state), do: failed(state, reason)

  defp failed(state, reason) do
    Logger.warning(
      "k8s controller: config #{state.path} rejected, keeping the last good one: " <>
        inspect(reason, limit: 8)
    )

    {{:error, reason}, set_degraded(state, ["bad_config"])}
  end

  defp set_degraded(%{degraded: words} = state, words), do: state

  defp set_degraded(state, words) do
    tell(state, {:controller_degraded, self(), words})
    %{state | degraded: words}
  end

  defp tell(%{subscribers: pids, announce?: true}, message),
    do: Enum.each(pids, &send(&1, message))

  defp tell(_state, _message), do: :ok
end
