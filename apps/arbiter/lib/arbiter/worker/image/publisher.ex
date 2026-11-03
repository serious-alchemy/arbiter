defmodule Arbiter.Worker.Image.Publisher do
  @moduledoc """
  Image publication on the primary (K8, bd-9vrbx7;
  `docs/design/remote-workers.md` §10.4, §11, amendment A2): builds the worker,
  seed and controller images and pushes them to the `nodes.registry` settings,
  returning **digest-pinned references** for `assign.image.ref`.

  With no registry (`nodes.registry` unset and none on the workspace or repo)
  every entry point answers `:disabled` and runs nothing, so an install that
  never configures a registry is unchanged. The run image goes to the registry
  `Registry.resolve/3` picks for its repo (repo -> workspace -> `nodes.registry`,
  KH12) with that registry's own credential; the controller image is always
  `nodes.registry`'s.

  ## What it publishes

    * `ensure_ready/2` — the **run image** for a plan: toolchain, warm `deps/_build`
      seed layer from `DepsCache`, then one layer per CLI of `Arbiter.Worker.CliSet`
      (`Pipeline`'s moduledoc has the layer and `seed_paths` rules);
    * `publish_controller/1` — the controller image, built from the retained
      release tarball and tagged with the server version. A boot task runs it
      shortly after each start (a deploy restarts the server), so the upgrade
      target exists before any node is told to move. Disabled in test.

  ## `ensure_ready/2`: single flight, bounded wait, clean fallback

  Publishing can take minutes (a cold toolchain, a cold `DepsCache`), so the
  caller waits at most `:timeout_ms` (default `nodes.registry.publish_timeout_ms`, 30 minutes,
  `config :arbiter, :image_publisher, timeout_ms:`) and gets
  `{:error, {:timeout, ms}}` instead of a hang. The publish **keeps going** in
  the server: a second caller for the same image joins the same flight rather
  than starting another, and once it finishes the result is cached, so the next
  dispatch is instant. A failure is never sticky. `fallback/2` is the policy
  for a caller that did not get an image: `prefer_remote` runs locally,
  `remote_only` holds the card (§7.3).

  ### `wait: false`: do not park the caller (bd-5fpj59)

  A dispatch that holds a board-promotion slot must not sit out a 14-minute cold
  publish. With `wait: false` the call answers at once: `{:ok, result}` when the
  image is cached, `{:pending, key}` when a publish is (now) running, or
  `{:error, reason}` once when the last publish for this image failed (the
  failure is handed over a single time, never sticky, so the call after that
  starts a new publish). `on_done: (key, result -> any)` is called when the
  flight settles, success or failure, so the caller can wake whatever is
  holding work for that image. Single flight is unchanged: a second caller,
  waiting or not, joins the running publish.

  Credentials: see `Arbiter.Worker.Image.Registry`.

  ## Options

  `:wait` (`false` for the non-blocking form above) and `:on_done`,
  `:server`, `:timeout_ms`, `:config` (install registry map, see `Registry.fetch/1`),
  `:anonymous_probe` (`(Registry.t, repository -> :public | :private | {:unknown, _})`,
  the private-registry check, see `ensure_ready/2`),
  `:runner` (podman, see `Image.run/3`), `:builder`, `:scratch`, `:cli_set` and the other
  `Arbiter.Worker.CliSet.option_keys/0` (which pinned CLI cache the layers come from), `:deps_ensure`
  (`(repo, base, image_tag, opts -> {:ok, %{dir:, lock_hash:}} | {:error, _})`),
  `:resolver`, `:artifact`, `:fingerprint` (`(ctx -> term)`, what invalidates a cached image), `:probe` (status reachability, `(Registry.t() -> :ok
  | {:error, term})`).
  """

  use GenServer

  alias Arbiter.Nodes.Prefetch
  alias Arbiter.Settings
  alias Arbiter.Worker.CliSet
  alias Arbiter.Worker.Image.Prebuilt
  alias Arbiter.Worker.Image.Publisher.Pipeline
  alias Arbiter.Worker.Image.PublishLedger
  alias Arbiter.Worker.Image.Registry
  alias Arbiter.Worker.Image.RegistryReport

  require Logger

  @default_boot_delay_ms 15_000

  # -- client -------------------------------------------------------------------

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  The run image for `ctx` (`%{plan:, repo:, repo_path:, base:, seed_paths:}`; `repo` names
  the `<registry>/<repo>/worker` repository it is pushed to; `workspace` is where
  its registry and credential are resolved):
  `{:ok, result}` with a digest-pinned `ref`, `:disabled` when no registry is
  configured, or `{:error, reason}` (`{:timeout, ms}`, `{:push_failed, …}`,
  `{:registry_credentials, ref, reason}`, `{:public_registry, repository}`, …).

  A repository on any registry (the workspace config's, or the install-wide
  `nodes.registry`, SI12) that answers anonymous reads is refused, as every
  image carries the real `claude` binary, unless that registry sets `public_ok` (`nodes.registry_public_ok` for the install-wide one).
  An answer the probe could not give is not a refusal.
  """
  @spec ensure_ready(map(), keyword()) ::
          {:ok, Pipeline.result()} | {:pending, term()} | :disabled | {:error, term()}
  def ensure_ready(%{plan: _} = ctx, opts \\ []) do
    case Registry.resolve(Map.get(ctx, :workspace), Map.get(ctx, :repo), opts) do
      :unset ->
        :disabled

      {:error, _} = error ->
        error

      {:ok, cfg} ->
        key = image_key(ctx, cfg, opts)

        key
        |> flight(
          :worker,
          fn ->
            with :ok <- ensure_private(cfg, ctx, opts), do: Pipeline.publish_image(ctx, cfg, opts)
          end,
          opts
        )
        |> tap(&published(&1, ctx, opts))
    end
  end

  # The ledger notes the publish; SI7: a ref the repo had not published before is
  # announced to the nodes that could take its runs (`Nodes.Prefetch`, in the background).
  defp published({:ok, %{ref: ref} = result}, ctx, opts) when is_binary(ref) do
    previous = PublishLedger.last_ref(Map.get(ctx, :repo), opts)

    PublishLedger.record(
      ctx,
      opts |> Keyword.put(:ref, ref) |> Keyword.put(:image, image_facts(result))
    )

    if previous != ref, do: Prefetch.after_publish(ctx, result, opts)
    :ok
  end

  defp published(_result, _ctx, _opts), do: :ok

  # What the doctor's `image <repo>` row shows (SI11): the CLI set, the providers it
  # lists and the seed layer's outcome.
  defp image_facts(result) do
    seed = Map.get(result, :seed) || %{}

    %{
      providers: Map.get(result, :providers),
      clis: Map.get(result, :clis),
      seed: %{status: Map.get(seed, :status), reason: Map.get(seed, :reason)}
    }
  end

  defp ensure_private(%Registry{public_ok: false} = cfg, ctx, opts) do
    repository = Pipeline.worker_repository(ctx)

    probe = Keyword.get_lazy(opts, :anonymous_probe, &anonymous_probe/0)

    case probe.(cfg, repository) do
      :public ->
        {:error, {:public_registry, Registry.repository(cfg, repository)}}

      {:unknown, reason} ->
        Logger.warning(
          "Image.Publisher: could not tell whether #{Registry.repository(cfg, repository)} " <>
            "is private: #{inspect(reason)}"
        )

        :ok

      _ ->
        :ok
    end
  end

  defp ensure_private(_cfg, _ctx, _opts), do: :ok

  # What the published image depends on: the toolchain tag, the repo (its image
  # repository) whose
  # `DepsCache` seeds it (two repos can share a toolchain tag), the seed rules
  # and base, and a fingerprint of the inputs that change under a running server
  # (the CLI set's content hash, `mix.lock`), so an update publishes again
  # rather than serving a stale `ref`. An entry for an older fingerprint is
  # dropped when the new one lands (`record_success/4`).
  defp image_key(%{plan: plan} = ctx, cfg, opts) do
    {:image, cfg.registry, plan.tag, Map.get(ctx, :repo), Map.get(ctx, :repo_path),
     Map.get(ctx, :seed_paths), Map.get(ctx, :base), fingerprint(ctx, opts)}
  end

  defp fingerprint(ctx, opts) do
    case Keyword.fetch(opts, :fingerprint) do
      {:ok, fun} -> fun.(ctx)
      :error -> %{cli: cli_stamp(opts), lock: lock_stamp(ctx)}
    end
  end

  # The CLI set's content hash (`Arbiter.Worker.CliSet`), not path, size and mtime:
  # a CLI bump with new bytes publishes again, and the same bytes under a new
  # file never do. Read from the cache manifests, so cheap.
  defp cli_stamp(opts) do
    case CliSet.resolve(opts) do
      {:ok, set} -> set.hash
      {:error, reason} -> reason
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

    if Keyword.get(opts, :wait, true) == false,
      do: flight_nowait(server, key, kind, fun, Keyword.get(opts, :on_done)),
      else: flight_wait(server, key, kind, fun, opts)
  end

  defp flight_nowait(server, key, kind, fun, on_done) do
    GenServer.call(server, {:ensure_nowait, key, kind, fun, on_done}, 5_000)
  catch
    :exit, {:noproc, _} -> {:error, :publisher_not_running}
    :exit, {:timeout, _} -> {:error, :publisher_busy}
  end

  defp flight_wait(server, key, kind, fun, opts) do
    timeout =
      Keyword.get_lazy(opts, :timeout_ms, fn ->
        config(:timeout_ms, Settings.publish_timeout_ms())
      end)

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
  publish error and the `seed_paths` entries K26 excluded, plus `registries`: one
  entry per registry in use, `nodes.registry` or a workspace's, with its
  reachability and anonymous-read probe (`RegistryReport`), and `images`: one check
  per `prebuilt` repo (`Prebuilt.report/1`, KH14). Never a password.
  """
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    probe = Keyword.get_lazy(opts, :probe, fn -> config(:probe, &Registry.reachable/1) end)

    registries =
      opts
      |> Keyword.put(:probe, probe)
      |> Keyword.put_new_lazy(:anonymous_probe, &anonymous_probe/0)
      |> RegistryReport.build()

    images = Prebuilt.report(opts)

    case Registry.fetch(opts) do
      :unset ->
        %{
          configured: false,
          registries: registries,
          images: images,
          repo_images: PublishLedger.images(opts)
        }

      {:ok, cfg} ->
        %{reachable: reachable, reachable_detail: detail} =
          Enum.find(registries, &(&1.origin == "install"))

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
          seed_excluded: snapshot.seed_excluded,
          registries: registries,
          images: images,
          repo_images: PublishLedger.images(opts)
        }
    end
  end

  @doc """
  What has been published since boot, newest first (`%{kind, ref, tag, at}`, one per
  kind), without probing the registry: what a cluster controller's canary may run
  (`Arbiter.Nodes.ClusterInstall.controller_facts/1`). `[]` when nothing is running.
  """
  @spec published(keyword()) :: [map()]
  def published(opts \\ []), do: snapshot(Keyword.get(opts, :server, __MODULE__)).published

  defp snapshot(server) do
    GenServer.call(server, :snapshot, 5_000)
  catch
    :exit, _ -> %{published: [], last_error: nil, seed_excluded: []}
  end

  defp anonymous_probe, do: config(:anonymous_probe, &Registry.anonymous_read/2)

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
       failed: %{},
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

  # bd-5fpj59: the caller does not wait. Its `on_done` rides in the waiter list
  # as `{:notify, fun}` and runs when the flight settles.
  def handle_call({:ensure_nowait, key, kind, fun, on_done}, _from, state) do
    case state do
      %{cache: %{^key => result}} ->
        {:reply, {:ok, result}, state}

      %{failed: %{^key => reason}} ->
        {:reply, {:error, reason}, %{state | failed: Map.delete(state.failed, key)}}

      _ ->
        {:reply, {:pending, key}, join_or_start(state, key, kind, fun, {:notify, on_done})}
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

    state = remember_failure(state, key, waiters, result)
    Enum.each(waiters, &reply_waiter(&1, key, result))
    state
  end

  # A failure is remembered (until a no-wait caller collects it) only when
  # someone who did not wait was told to expect the result.
  defp remember_failure(state, key, waiters, {:error, reason}) do
    if Enum.any?(waiters, &match?({:notify, _}, &1)),
      do: %{state | failed: Map.put(state.failed, key, reason)},
      else: state
  end

  defp remember_failure(state, key, _waiters, _result),
    do: %{state | failed: Map.delete(state.failed, key)}

  defp reply_waiter({:notify, nil}, _key, _result), do: :ok

  defp reply_waiter({:notify, fun}, key, result) when is_function(fun, 2) do
    fun.(key, result)
  rescue
    e -> Logger.warning("Image.Publisher: on_done callback failed: #{Exception.message(e)}")
  catch
    kind, reason ->
      Logger.warning("Image.Publisher: on_done callback #{kind}: #{inspect(reason)}")
  end

  defp reply_waiter(from, _key, result), do: GenServer.reply(from, result)

  # An image entry is superseded by the same image under a newer fingerprint.
  defp drop_superseded(cache, {:image, _, _, _, _, _, _, _} = key) do
    prefix = key |> Tuple.delete_at(7) |> Tuple.to_list()

    Map.reject(cache, fn
      {{:image, _, _, _, _, _, _, _} = other, _} ->
        other != key and other |> Tuple.delete_at(7) |> Tuple.to_list() == prefix

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
