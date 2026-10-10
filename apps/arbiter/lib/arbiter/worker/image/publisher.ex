defmodule Arbiter.Worker.Image.Publisher do
  @moduledoc """
  Image publication on the primary (K8, bd-9vrbx7;
  `docs/design/remote-workers.md` §10.4, §11, amendment A2): builds the worker,
  seed and controller images and pushes them to the `nodes.registry` settings,
  returning **digest-pinned references** for `assign.image.ref`.

  With `nodes.registry` unset every entry point answers `:disabled` and runs
  nothing, so an install that never configures a registry is unchanged.

  ## What it publishes

    * `ensure_ready/2` — the **run image** for a plan: toolchain, CLI layer
      (`claude` + `arb`) and warm `deps/_build` seed layer from `DepsCache`
      (`Pipeline`'s moduledoc has the layer and `seed_paths` rules);
    * `publish_controller/1` — the controller image, built from the retained
      release tarball and tagged with the server version. A boot task runs it
      shortly after each start (a deploy restarts the server), so the upgrade
      target exists before any node is told to move. Disabled in test.

  ## `ensure_ready/2`: single flight, bounded wait, clean fallback

  Publishing can take minutes (a cold toolchain, a cold `DepsCache`), so the
  caller waits at most `:timeout_ms` (default #{div(600_000, 60_000)} minutes,
  `config :arbiter, :image_publisher, timeout_ms:`) and gets
  `{:error, {:timeout, ms}}` instead of a hang. The publish **keeps going** in
  the server: a second caller for the same image joins the same flight rather
  than starting another, and once it finishes the result is cached, so the next
  dispatch is instant. A failure is never sticky. `fallback/2` is the policy
  for a caller that did not get an image: `prefer_remote` runs locally,
  `remote_only` holds the card (§7.3).

  Credentials: see `Arbiter.Worker.Image.Registry`.

  ## Options

  `:server`, `:timeout_ms`, `:config` (registry map, see `Registry.fetch/1`),
  `:runner` (podman, see `Image.run/3`), `:builder`, `:scratch`, `:cli`
  (`[{host_path, container_path}]`), `:deps_ensure`
  (`(repo, base, image_tag, opts -> {:ok, %{dir:, lock_hash:}} | {:error, _})`),
  `:resolver`, `:artifact`, `:fingerprint` (`(ctx -> term)`, what invalidates a cached image), `:probe` (status reachability, `(Registry.t() -> :ok
  | {:error, term})`).
  """

  use GenServer

  alias Arbiter.Worker.Image.Publisher.Pipeline
  alias Arbiter.Worker.Image.Registry

  require Logger

  @default_timeout_ms 600_000
  @default_boot_delay_ms 15_000
  @probe_timeout_ms 3_000

  # -- client -------------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  The run image for `ctx` (`%{plan:, repo_path:, base:, seed_paths:}`):
  `{:ok, result}` with a digest-pinned `ref`, `:disabled` when no registry is
  configured, or `{:error, reason}` (`{:timeout, ms}`, `{:push_failed, …}`, …).
  """
  @spec ensure_ready(map(), keyword()) ::
          {:ok, Pipeline.result()} | :disabled | {:error, term()}
  def ensure_ready(%{plan: _} = ctx, opts \\ []) do
    case Registry.fetch(opts) do
      :unset ->
        :disabled

      {:ok, cfg} ->
        key = image_key(ctx, cfg, opts)
        flight(key, :worker, fn -> Pipeline.publish_image(ctx, cfg, opts) end, opts)
    end
  end

  # What the published image depends on: the toolchain tag, the repo whose
  # `DepsCache` seeds it (two repos can share a toolchain tag), the seed rules
  # and base, and a fingerprint of the inputs that change under a running server
  # (the `claude`/`arb` binaries, `mix.lock`), so an update publishes again
  # rather than serving a stale `ref`. An entry for an older fingerprint is
  # dropped when the new one lands (`record_success/4`).
  defp image_key(%{plan: plan} = ctx, cfg, opts) do
    {:image, cfg.registry, plan.tag, Map.get(ctx, :repo_path), Map.get(ctx, :seed_paths),
     Map.get(ctx, :base), fingerprint(ctx, opts)}
  end

  defp fingerprint(ctx, opts) do
    case Keyword.fetch(opts, :fingerprint) do
      {:ok, fun} -> fun.(ctx)
      :error -> %{cli: cli_stamp(opts), lock: lock_stamp(ctx)}
    end
  end

  defp cli_stamp(opts) do
    case Pipeline.cli_files(opts) do
      {:ok, files} ->
        for {host, _dest} <- files do
          case File.stat(host, time: :posix) do
            {:ok, stat} -> {host, stat.size, stat.mtime}
            {:error, reason} -> {host, reason}
          end
        end

      {:error, reason} ->
        reason
    end
  end

  defp lock_stamp(%{plan: plan, repo_path: repo, base: base}) when is_binary(repo) do
    case Arbiter.Worker.DepsCache.key(repo, base || "main", plan.tag) do
      {:ok, %{lock_hash: hash}} -> hash
      {:error, reason} -> reason
    end
  end

  defp lock_stamp(_ctx), do: nil

  @doc "Build and push the controller image for the running release."
  @spec publish_controller(keyword()) :: {:ok, Pipeline.result()} | :disabled | {:error, term()}
  def publish_controller(opts \\ []) do
    case Registry.fetch(opts) do
      :unset ->
        :disabled

      {:ok, cfg} ->
        # Keyed by registry only: the version rides in the result. A redeploy is a
        # new BEAM, so the cache is empty again.
        flight(
          {:controller, cfg.registry},
          :controller,
          fn -> Pipeline.publish_controller(cfg, opts) end,
          opts
        )
    end
  end

  @doc """
  What to do when `ensure_ready/2` gave no image, by `worker.placement`:
  `prefer_remote` and `local_only` run on the primary (`{:local, reason}`),
  `remote_only` holds the card (`{:hold, reason}`).
  """
  @spec fallback(atom(), term()) :: {:local, term()} | {:hold, term()}
  def fallback(:remote_only, reason), do: {:hold, reason}
  def fallback(_mode, reason), do: {:local, reason}

  defp flight(key, kind, fun, opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout_ms, config(:timeout_ms, @default_timeout_ms))

    try do
      GenServer.call(server, {:ensure, key, kind, fun}, timeout)
    catch
      :exit, {:timeout, _} -> {:error, {:timeout, timeout}}
      :exit, {:noproc, _} -> {:error, :publisher_not_running}
    end
  end

  @doc """
  The registry as the doctor reports it (`GET /api/nodes` → `registry`):
  configured or not, reachability, what has been published since boot, the last
  publish error and the `seed_paths` entries K26 excluded. Never the password.
  """
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    case Registry.fetch(opts) do
      :unset ->
        %{configured: false}

      {:ok, cfg} ->
        {reachable, detail} = probe(cfg, opts)
        snapshot = snapshot(Keyword.get(opts, :server, __MODULE__))

        %{
          configured: true,
          registry: cfg.registry,
          username: cfg.username,
          password_set: not is_nil(cfg.password),
          insecure: cfg.insecure?,
          reachable: reachable,
          reachable_detail: detail,
          published: snapshot.published,
          last_error: snapshot.last_error,
          seed_excluded: snapshot.seed_excluded
        }
    end
  end

  defp snapshot(server) do
    GenServer.call(server, :snapshot, 5_000)
  catch
    :exit, _ -> %{published: [], last_error: nil, seed_excluded: []}
  end

  defp probe(cfg, opts) do
    probe = Keyword.get_lazy(opts, :probe, fn -> config(:probe, &default_probe/1) end)

    case probe.(cfg) do
      :ok -> {true, nil}
      {:error, reason} -> {false, inspect(reason)}
    end
  end

  # `GET /v2/`: 200 (open) and 401 (auth required) both mean a registry answered.
  defp default_probe(%Registry{host: host, insecure?: insecure?}) do
    schemes = if insecure?, do: ["https", "http"], else: ["https"]
    transport = if insecure?, do: [transport_opts: [verify: :verify_none]], else: []

    Enum.reduce_while(schemes, {:error, :unreachable}, fn scheme, _ ->
      case Req.get("#{scheme}://#{host}/v2/",
             retry: false,
             receive_timeout: @probe_timeout_ms,
             connect_options: [timeout: @probe_timeout_ms] ++ transport,
             redirect: false
           ) do
        {:ok, %Req.Response{status: status}} when status in [200, 401] -> {:halt, :ok}
        {:ok, %Req.Response{status: status}} -> {:cont, {:error, {:http_status, status}}}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  defp config(key, default),
    do: :arbiter |> Application.get_env(:image_publisher, []) |> Keyword.get(key, default)

  # -- server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok, sup} = Task.Supervisor.start_link()

    if Keyword.get(opts, :boot, config(:boot, true)) do
      Process.send_after(self(), :boot, Keyword.get(opts, :boot_delay_ms, @default_boot_delay_ms))
    end

    {:ok,
     %{
       sup: sup,
       cache: %{},
       inflight: %{},
       tasks: %{},
       published: %{},
       last_error: nil,
       seed_excluded: []
     }}
  end

  @impl true
  def handle_call({:ensure, key, kind, fun}, from, state) do
    case state.cache do
      %{^key => result} -> {:reply, {:ok, result}, state}
      _ -> {:noreply, join_or_start(state, key, kind, fun, from)}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       published: state.published |> Map.values() |> Enum.sort_by(& &1.at, {:desc, DateTime}),
       last_error: state.last_error,
       seed_excluded: state.seed_excluded
     }, state}
  end

  @impl true
  def handle_info(:boot, state) do
    state =
      case Registry.fetch() do
        {:ok, cfg} ->
          key = {:controller, cfg.registry}

          join_or_start(
            state,
            key,
            :controller,
            fn -> Pipeline.publish_controller(cfg, []) end,
            nil
          )

        :unset ->
          state
      end

    {:noreply, state}
  end

  def handle_info({ref, result}, %{tasks: tasks} = state) when is_map_key(tasks, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {:noreply, finish(state, ref, {:error, {:publish_crashed, inspect(reason)}})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp join_or_start(state, key, kind, fun, from) do
    waiters = List.wrap(from)

    case state.inflight do
      %{^key => existing} ->
        put_in(state.inflight[key], waiters ++ existing)

      _ ->
        task = Task.Supervisor.async_nolink(state.sup, fun)

        %{
          state
          | inflight: Map.put(state.inflight, key, waiters),
            tasks: Map.put(state.tasks, task.ref, {key, kind})
        }
    end
  end

  defp finish(state, ref, result) do
    {{key, kind}, tasks} = Map.pop(state.tasks, ref)
    {waiters, inflight} = Map.pop(state.inflight, key, [])
    state = %{state | tasks: tasks, inflight: inflight}

    state =
      case result do
        {:ok, published} ->
          Logger.info("Image.Publisher: published #{kind} image #{published.ref}")
          record_success(state, key, kind, published)

        {:error, reason} ->
          Logger.warning("Image.Publisher: #{kind} publish failed: #{inspect(reason)}")
          %{state | last_error: "#{kind}: #{inspect(reason)}"}
      end

    Enum.each(waiters, &GenServer.reply(&1, result))
    state
  end

  # An image entry is superseded by the same image under a newer fingerprint.
  defp drop_superseded(cache, {:image, _, _, _, _, _, _} = key) do
    prefix = key |> Tuple.delete_at(6) |> Tuple.to_list()

    Map.reject(cache, fn
      {{:image, _, _, _, _, _, _} = other, _} ->
        other != key and other |> Tuple.delete_at(6) |> Tuple.to_list() == prefix

      _ ->
        false
    end)
  end

  defp drop_superseded(cache, _key), do: cache

  defp record_success(state, key, kind, published) do
    entry = %{kind: kind, ref: published.ref, tag: published.tag, at: DateTime.utc_now()}
    excluded = get_in(published, [:seed, :excluded]) || []

    %{
      state
      | cache: state.cache |> drop_superseded(key) |> Map.put(key, published),
        published: Map.put(state.published, kind, entry),
        last_error: nil,
        seed_excluded: if(kind == :worker, do: excluded, else: state.seed_excluded)
    }
  end
end
