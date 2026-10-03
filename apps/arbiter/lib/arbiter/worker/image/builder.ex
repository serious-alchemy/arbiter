defmodule Arbiter.Worker.Image.Builder do
  @moduledoc """
  Lazy, single-flight image builds (bd-9r5jdt, design §2.4).

  `ensure/3` takes an `Arbiter.Worker.Image.plan/3` and returns once its tag
  exists locally: immediately when it already does, otherwise after one
  `podman build`. The base layer is ensured first, then the toolchain layer.
  Each layer is its own flight, keyed by its content-hash tag:

    * **Single-flight** — callers asking for a tag that is already being built
      queue behind that build and share its result; they never start a second
      one. A tag that finishes building is then simply "present".
    * **Independent tags build in parallel**, so two toolchains never wait on
      each other once the shared base exists.
    * **Failure is not sticky** — every waiter gets `{:error, {:build_failed,
      tag, status, output}}`, the flight is forgotten, and the next request
      builds again.

  A build runs unprivileged with network (the base and toolchain installs need
  it) from an **empty context directory** holding only the Containerfile text
  the plan carries, which came from the default branch (see
  `Arbiter.Worker.Image`). The directory is removed afterwards.
  """

  use GenServer

  alias Arbiter.Config.Paths
  alias Arbiter.Worker.Image

  @build_timeout_ms 20 * 60_000
  @call_margin_ms 30_000

  @type result :: {:ok, %{tag: String.t(), built: [String.t()]}} | {:error, term()}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, if(name, do: [name: name], else: []))
  end

  @doc """
  Ensure `plan`'s image (and its base) exist. `built` lists the tags this call
  waited on a build for (empty when everything was already present).

  Options: `:runner` (see `Arbiter.Worker.Image.run/3`), `:scratch` (where build
  directories go, default `<scratch_root>/images`), `:timeout` (per build).
  """
  @spec ensure(GenServer.server(), Image.plan(), keyword()) :: result()
  def ensure(server \\ __MODULE__, plan, opts \\ []) do
    base = Map.put(plan.base, :build_args, [])
    toolchain = Map.take(plan, [:tag, :name, :hash, :containerfile, :build_args])

    with {:ok, built_base} <- ensure_layer(server, base, opts),
         {:ok, built} <- ensure_layer(server, toolchain, opts) do
      {:ok, %{tag: plan.tag, built: built_base ++ built}}
    end
  end

  defp ensure_layer(server, layer, opts) do
    timeout = Keyword.get(opts, :timeout, @build_timeout_ms)

    GenServer.call(server, {:ensure, layer, opts}, timeout + @call_margin_ms)
  end

  # -- server ------------------------------------------------------------------

  @impl true
  def init(:ok) do
    {:ok, sup} = Task.Supervisor.start_link()
    {:ok, %{sup: sup, inflight: %{}, tasks: %{}}}
  end

  @impl true
  def handle_call({:ensure, layer, opts}, from, state) do
    tag = layer.tag

    case state.inflight do
      %{^tag => waiters} ->
        {:noreply, put_in(state.inflight[tag], [from | waiters])}

      _ ->
        task =
          Task.Supervisor.async_nolink(state.sup, fn -> build_if_missing(layer, opts) end)

        state = %{
          state
          | inflight: Map.put(state.inflight, tag, [from]),
            tasks: Map.put(state.tasks, task.ref, tag)
        }

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({ref, result}, %{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {:noreply, finish(state, ref, {:error, {:build_crashed, inspect(reason)}})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp finish(state, ref, result) do
    {tag, tasks} = Map.pop(state.tasks, ref)
    {waiters, inflight} = Map.pop(state.inflight, tag, [])
    Enum.each(waiters, &GenServer.reply(&1, result))
    %{state | tasks: tasks, inflight: inflight}
  end

  # -- the build ---------------------------------------------------------------

  defp build_if_missing(layer, opts) do
    if Image.exists?(layer.tag, opts) do
      {:ok, []}
    else
      build(layer, opts)
    end
  end

  defp build(layer, opts) do
    root = Keyword.get_lazy(opts, :scratch, fn -> Path.join(Paths.scratch_root(), "images") end)

    dir =
      Path.join(root, "build-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}")

    context = Path.join(dir, "context")
    file = Path.join(dir, "Containerfile")

    try do
      File.mkdir_p!(context)
      File.write!(file, layer.containerfile)

      case Image.run("podman", build_args(layer, file, context), timeout(opts, opts)) do
        {_, 0} -> {:ok, [layer.tag]}
        {output, status} -> {:error, {:build_failed, layer.tag, status, tail(output)}}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp timeout(opts, run_opts),
    do: Keyword.put(run_opts, :timeout, Keyword.get(opts, :timeout, @build_timeout_ms))

  defp build_args(layer, file, context) do
    ["build", "--file", file, "--tag", layer.tag] ++
      ["--label", "#{Image.label()}=1"] ++
      ["--label", "#{Image.label()}.name=#{layer.name}"] ++
      ["--label", "#{Image.label()}.hash=#{layer.hash}"] ++
      Enum.flat_map(layer.build_args, fn {name, value} -> ["--build-arg", "#{name}=#{value}"] end) ++
      [context]
  end

  # The end of a build log is where the failing step is.
  defp tail(output) do
    output = String.trim(output)
    String.slice(output, max(String.length(output) - 1_500, 0), 1_500)
  end
end
