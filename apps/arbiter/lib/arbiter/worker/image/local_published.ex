defmodule Arbiter.Worker.Image.LocalPublished do
  @moduledoc """
  A local run takes the SAME published per-repo image as every node and pod (SI-L,
  bd-4cq0qt, operator decision OD11: "keep things running the same way everywhere"),
  served from the local podman image store so it stays fast.

  `resolve/1` is the local image step of `Arbiter.Worker.ContainerSpawn.prepare/1`:

    1. **Which digest.** The repo's latest published digest, from the publish ledger
       (`PublishLedger.last_ref/2`). Nothing is built or pushed at spawn time.
    2. **Present?** `podman image exists <ref>`: a cached digest starts with no
       network at all.
    3. **Pull** otherwise, with SI4's pull (`Arbiter.NodeAgent.ImagePull`): a credential
       written as a containers auth file onto the run's tmpfs only, removed when the pull
       ends, never `podman login`. Layers are content addressed, so a CLI-only change
       fetches only the changed layer. The credential is the repo's pull credential
       (`PullCredential.for_local/3`, no reach rule: this *is* the primary), else the
       registry's own login the primary already pushes with, else anonymous.
    4. **Check** the image's labels against the CLI set the primary pinned, like a node.

  The result is `{:published, %{ref: ref}}` (the run uses the ref and mounts no CLIs),
  `{:build, nil}` (no registry configured, or the step is switched off: today's path, with
  nothing to record), or `{:fallback, reason}`: the registry is configured but the digest
  cannot be had (never published, cold cache with the registry unreachable, a refused
  credential, a label mismatch). The caller then builds locally and bind-mounts the CLIs,
  and records `reason` on the run (`image_fallback`, SI3): **a run is never stranded by
  this step**, it can only be a slower, older-shaped one.

  ## Warm before the run, collected safely

  `prefetch/3` is SI7's `image.prefetch` aimed at this machine: `Arbiter.Nodes.Prefetch`
  calls it after each publish, in the background, so the store is usually warm before a
  run. `gc_spec/1` is the child spec of a second `Arbiter.NodeAgent.ImageGC` over the
  local store: its ledger holds only what this module pulled, so an image the operator
  pulled or built is out of its reach, and a digest a live run uses
  (`Arbiter.Worker.Image.LocalRuns`) is never removed; `podman rmi` (never `-f`) refuses
  an image a container still uses besides.

  Switched off at runtime by `worker.image.local_published` false (`arb settings set`,
  no restart; the GC then removes nothing), or by `config :arbiter, :local_published_image, false` (the test suite's
  default) or `published_image: false` in the options. Options: `:workspace`, `:repo`,
  `:run` (the container name; the GC ledger's run id), `:owner`, `:provider`,
  `:expect_cli_set` (the pinned set8 the image must carry), `:ledger` (`PublishLedger`),
  `:registry_opts` (`Registry.resolve/3`), `:credential_opts`, `:gc` (`ImageGC`'s `:name`),
  `:runs` (`LocalRuns`' options), `:pull_timeout_ms` and `ImagePull`'s `:podman`,
  `:runner`, `:runtime_dir`, `:require_tmpfs`, `:mountinfo`.
  """

  alias Arbiter.Config.Paths
  alias Arbiter.NodeAgent.{ImageGC, ImagePull, PullAuth, Secrets}
  alias Arbiter.Worker.Image.{LocalRuns, PublishLedger, PullCredential, Registry}

  require Logger

  # A cold pull on a laptop is bounded: the run falls back to the local build rather
  # than wait on a slow link (the pull keeps its layers, so the next run is warmer).
  @pull_timeout_ms 5 * 60_000

  @type result ::
          {:published, %{ref: String.t(), cli_set: String.t() | nil}}
          | {:build, nil}
          | {:fallback, String.t()}

  @doc "Whether local runs take the published image (the app env and `published_image:`)."
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts \\ []) do
    case Keyword.fetch(opts, :published_image) do
      {:ok, value} -> value != false
      :error -> setting_or_config()
    end
  end

  # The runtime switch (`worker.image.local_published`, `arb settings set`) wins over the
  # app env; unset falls back to `config :arbiter, :local_published_image` (default on).
  defp setting_or_config do
    case Arbiter.Settings.worker_image_local_published() do
      nil -> Application.get_env(:arbiter, :local_published_image, true) != false
      value -> value != false
    end
  end

  @doc "The image step of a local spawn. See the moduledoc."
  @spec resolve(keyword()) :: result()
  def resolve(opts) do
    repo = Keyword.get(opts, :repo)
    workspace = Keyword.get(opts, :workspace)

    with true <- enabled?(opts) || {:build, nil},
         {:ok, cfg} <- registry(workspace, repo, opts),
         {:ok, ref} <- latest(repo, opts),
         {:ok, auth} <- local_auth(workspace, repo, cfg, opts),
         :ok <- track_then_ensure(ref, cfg, auth, opts) do
      {:published, %{ref: ref, cli_set: Keyword.get(opts, :expect_cli_set)}}
    else
      {:build, nil} -> {:build, nil}
      {:fallback, reason} -> fallback(reason, opts)
    end
  end

  defp registry(workspace, repo, opts) do
    case Registry.resolve(workspace, repo, Keyword.get(opts, :registry_opts, [])) do
      {:ok, cfg} -> {:ok, cfg}
      :unset -> {:build, nil}
      {:error, reason} -> {:fallback, {:registry, reason}}
    end
  end

  defp latest(repo, opts) do
    case PublishLedger.last_ref(repo, ledger_opts(opts)) do
      ref when is_binary(ref) -> {:ok, ref}
      _ -> {:fallback, :never_published}
    end
  end

  defp ledger_opts(opts), do: Keyword.take(opts, [:ledger])

  # The pull credential if the repo has one; else the primary's own login for the
  # registry (it pushes with it, on this very host); else an anonymous pull.
  defp local_auth(workspace, repo, %Registry{} = cfg, opts) do
    case PullCredential.for_local(workspace, repo, Keyword.get(opts, :credential_opts, [])) do
      {:ok, %{auth: %PullAuth{} = auth}} ->
        {:ok, auth}

      _ ->
        {:ok, own_login(cfg)}
    end
  end

  defp own_login(%Registry{username: user, password: password, host: host})
       when is_binary(user) and user != "" and is_binary(password) and password != "",
       do: %PullAuth{registry: host, username: user, password: password}

  defp own_login(_cfg), do: nil

  # The run is live before its image is claimed, so no collection can slip between.
  defp track_then_ensure(ref, cfg, auth, opts) do
    track(opts)
    result = ensure(ref, cfg, auth, opts)
    Secrets.remove(runtime_dir(opts), run_id(opts))
    result
  end

  defp runtime_dir(opts) do
    case Secrets.runtime_dir(opts) do
      {:ok, dir} -> dir
      _ -> nil
    end
  end

  defp ensure(ref, %Registry{} = cfg, auth, opts) do
    image = %{
      insecure?: cfg.insecure? == true,
      cli_set: Keyword.get(opts, :expect_cli_set),
      provider: Keyword.get(opts, :provider)
    }

    pull_opts =
      opts
      |> Keyword.take([:podman, :runner, :runtime_dir, :require_tmpfs, :mountinfo, :gc])
      |> Keyword.put(:pull_timeout_ms, Keyword.get(opts, :pull_timeout_ms, @pull_timeout_ms))
      |> Keyword.put_new(:gc, name: gc_name())

    case ImagePull.ensure_ref(ref, image, auth, run_id(opts), pull_opts) do
      :ok -> :ok
      {:error, reason} -> {:fallback, reason}
    end
  end

  defp track(opts), do: LocalRuns.track(run_id(opts), Keyword.get(opts, :owner), runs_opts(opts))

  defp run_id(opts), do: Keyword.get(opts, :run) || "local-#{System.unique_integer([:positive])}"

  defp runs_opts(opts), do: Keyword.get(opts, :runs, [])

  defp fallback(reason, opts) do
    text = describe(reason)

    Logger.warning(
      "LocalPublished: #{Keyword.get(opts, :repo) || "the repo"} builds its image locally: #{text}"
    )

    {:fallback, text}
  end

  @doc "The one-line, credential-free form of a fallback reason, as recorded on the run."
  @spec describe(term()) :: String.t()
  def describe(:never_published), do: "never_published: no published image for the repo yet"

  def describe({:image_unavailable, {:pull_failed, status, _output}}),
    do: "pull_failed: podman pull exited #{status} (registry unreachable or refused)"

  def describe({:image_unavailable, {:contract_mismatch, item, found}}),
    do: "contract_mismatch: #{item} is #{inspect(found, limit: 4, printable_limit: 80)}"

  def describe({:image_unavailable, {kind, detail}}) when is_atom(kind),
    do: "#{kind}: #{inspect(detail, limit: 4, printable_limit: 120)}"

  def describe(other), do: inspect(other, limit: 6, printable_limit: 120)

  # -- prefetch ---------------------------------------------------------------------------

  @doc """
  SI7's `image.prefetch` for this machine: make `published.ref` present in the local
  store, with the same pull a run does. `:ok` also when there is nothing to do (switched
  off, no registry); an `{:error, reason}` is the pull's, and the next run pulls for itself.
  """
  @spec prefetch(map(), map(), keyword()) :: :ok | {:error, term()}
  def prefetch(ctx, %{ref: ref}, opts \\ []) when is_binary(ref) do
    opts = Keyword.merge([workspace: ctx[:workspace], repo: ctx[:repo]], opts)

    with true <- enabled?(opts) || :ok,
         {:ok, cfg} <- registry(opts[:workspace], opts[:repo], opts),
         {:ok, auth} <- local_auth(opts[:workspace], opts[:repo], cfg, opts) do
      pull_opts =
        opts
        |> Keyword.take([:podman, :runner, :runtime_dir, :require_tmpfs, :mountinfo, :gc])
        |> Keyword.put(:pull_timeout_ms, Keyword.get(opts, :pull_timeout_ms, @pull_timeout_ms))
        |> Keyword.put_new(:gc, name: gc_name())

      run = "prefetch-#{System.unique_integer([:positive])}"
      result = ImagePull.prefetch(ref, %{insecure?: cfg.insecure? == true}, auth, run, pull_opts)
      Secrets.remove(runtime_dir(opts), run)
      result
    else
      :ok -> :ok
      {:build, nil} -> :ok
      {:fallback, reason} -> {:error, reason}
    end
  end

  # -- the local store's GC ---------------------------------------------------------------

  @doc "The registered name of the local store's `ImageGC`."
  def gc_name, do: Arbiter.Worker.Image.LocalGC

  @doc """
  The child spec of the local store's GC: `Arbiter.NodeAgent.ImageGC` with its own
  ledger (`<image root>/local-store/images.json`) whose live runs are `LocalRuns`'.
  Options (tests): `:name`, `:runs` (`LocalRuns`' name), `:node_home`, and `ImageGC`'s.
  """
  @spec gc_spec(keyword()) :: Supervisor.child_spec()
  def gc_spec(opts \\ []) do
    runs = Keyword.get(opts, :runs, LocalRuns)

    home =
      Keyword.get_lazy(opts, :node_home, fn -> Path.join(Paths.image_root(), "local-store") end)

    gc_opts =
      opts
      |> Keyword.drop([:runs, :node_home])
      |> Keyword.put_new(:name, gc_name())
      |> Keyword.put(:config, %{node_home: home})
      |> Keyword.put(:runs_fun, fn -> LocalRuns.live(name: runs) end)
      |> Keyword.put_new(:skip_fun, fn ->
        Arbiter.Settings.worker_image_local_published() == false
      end)
      |> Keyword.put_new(:retained_fun, fn -> [] end)
      |> Keyword.put_new(:gate_fun, fn -> [] end)

    ImageGC.child_spec(gc_opts)
  end
end
