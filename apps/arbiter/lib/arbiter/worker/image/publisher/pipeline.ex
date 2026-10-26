defmodule Arbiter.Worker.Image.Publisher.Pipeline do
  @moduledoc """
  The build-and-push steps behind `Arbiter.Worker.Image.Publisher` (K8,
  `docs/design/remote-workers.md` §10.4, §11). Pure with respect to server
  state: each function takes the registry config and options and returns a
  result, so the single-flight server can run it in a task.

  ## Layers (§11)

  A `prebuilt` plan (KH14, `Arbiter.Worker.Image.Prebuilt`) has no toolchain
  layer: the repo's CI image is pulled by its digest and the seed and CLI layers
  are overlaid on it (the seed layer only for `seed: primary`).

  The run image is the last of these, each `FROM` the one before and pushed to
  `<registry>/<repo>/worker` (KH11, `RepoConfig.repository_name/1`: one repository
  per repo, no shared `<registry>/worker`):

    1. **toolchain** — `Image.Builder.ensure/3`'s image, tag `<hash12>`;
    2. **seed** — `DepsCache` output copied to `/opt/arbiter/seed`, tag
       `<hash12>-seed<lock12>-<seedpaths8>`. Best-effort: a repo with no
       lockfile, or a cache that cannot be seeded, publishes the CLI layers
       straight over the toolchain and says why;
    3. **CLI** — one `COPY` per CLI of `Arbiter.Worker.CliSet` in churn order
       (`codex`, `claude`, `arb`) into `/opt/arbiter/cli`, built with
       `--timestamp 0` so identical files are identical blobs, and tagged
       `<seed tag>-cli<set8>` (`<hash12>-cli<set8>` with no seed), `set8` being
       the set's content hash. The last image carries the `arbiter.cli-set`,
       `arbiter.cli-providers` and `arbiter.cli.<name>.*` labels and is the run
       image. A Claude update rebuilds the `claude` and `arb` layers and pushes
       one new blob; the toolchain and seed are reused by tag.

  The CLI layers sit above the seed (they used to sit below it, tagged
  `<hash12>-cli<sha8>[-seed...]`). The old tags are never rewritten or removed,
  so a digest handed to a pod before the change keeps resolving.

  Each layer is a `podman build` of a Containerfile written by this module (not
  by a worker) over a context that holds only what the layer ships. The
  DepsCache directory is used as a build context and never mounted into a
  container.

  ## `seed_paths` (K26)

  `worker.repos.<repo>.seed_paths` is intersected with what the layer can
  legitimately ship: entries equal to or under `deps` and `_build` are satisfied
  by `DepsCache` (built in the image, so the right ABI). **Every other entry is
  excluded** (for example `priv/plts`, a host-OTP artifact that may be wrong for
  the image's OTP) until a `seed_commands` mechanism exists; the exclusions are
  returned so the doctor can warn.

  ## Credentials

  A push gets its login from `Registry.with_authfile/3` (a 0600 file removed
  afterwards), never argv; any tool output stored in an error is passed through
  `Registry.redact/2` first.
  """

  alias Arbiter.Config.Paths
  alias Arbiter.Nodes.Agent
  alias Arbiter.Worker.CliSet
  alias Arbiter.Worker.DepsCache
  alias Arbiter.Worker.Image
  alias Arbiter.Worker.Image.Builder
  alias Arbiter.Worker.Image.Pins
  alias Arbiter.Worker.Image.Registry
  alias Arbiter.Worker.Image.RepoConfig

  @cli_dest "/opt/arbiter/cli/"
  @seed_dest "/opt/arbiter/seed"
  # Every CLI layer is built at this instant, so identical files are identical blobs.
  @cli_timestamp "0"
  @seed_artifacts ["deps", "_build"]
  @mix_home "mix_home"
  @controller_base "FROM docker.io/library/debian:trixie-slim"
  @controller_uid 10_001
  @push_timeout_ms 30 * 60_000
  @build_timeout_ms 30 * 60_000
  @quick_timeout_ms 60_000

  @type layer :: %{
          layer: :toolchain | :cli | :seed | :controller,
          tag: String.t(),
          tag_ref: String.t(),
          digest: String.t(),
          ref: String.t()
        }

  @type result :: %{
          ref: String.t(),
          tag_ref: String.t(),
          tag: String.t(),
          layers: [layer()],
          seed: %{status: :pushed | :skipped, reason: String.t() | nil, excluded: [String.t()]}
        }

  # -- the worker image ---------------------------------------------------------

  @doc """
  Build (if missing) and push the toolchain, CLI and seed layers of `ctx.plan`
  (`%{plan:, repo_path:, base:, seed_paths:}`); the run image's reference is the
  last layer's.
  """
  @spec publish_image(map(), Registry.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def publish_image(%{plan: %{source: :prebuilt} = plan} = ctx, %Registry{} = cfg, opts) do
    repository = worker_repository(ctx)

    with :ok <- pull(plan.tag, cfg, opts) do
      workdir(opts, &upper_layers(ctx, repository, [], &1, cfg, opts))
    end
  end

  def publish_image(%{plan: plan} = ctx, %Registry{} = cfg, opts) do
    builder = Keyword.get(opts, :builder, Builder)
    repository = worker_repository(ctx)

    with {:ok, _} <- Builder.ensure(builder, plan, Keyword.take(opts, [:runner, :scratch])),
         {:ok, toolchain} <- push(plan.tag, repository, plan.hash, :toolchain, cfg, opts) do
      workdir(opts, &upper_layers(ctx, repository, [toolchain], &1, cfg, opts))
    end
  end

  # The best-effort seed layer over the toolchain, then one CLI layer per CLI over
  # that (SI1, OD14): the CLIs change far more often than the seed, so they sit on
  # top and a CLI update pushes only the layers above it. The set is resolved
  # first: a missing claude fails the publish before a seed is built.
  defp upper_layers(%{plan: plan} = ctx, repository, toolchain, work, cfg, opts) do
    with {:ok, set} <- cli_set(opts) do
      {seed, seed_report} = seed_layer(ctx, plan, repository, work, cfg, opts)
      parent = if seed, do: seed.local, else: plan.tag
      tag = if(seed, do: seed.tag, else: plan.hash) <> "-cli" <> set.set8

      with {:ok, cli} <- cli_layers(set, parent, tag, repository, work, cfg, opts) do
        layers = toolchain ++ List.wrap(seed) ++ [cli]
        cleanup_local(Enum.reverse(Enum.flat_map(layers, &chain/1)), opts)

        {:ok,
         %{
           ref: cli.ref,
           tag_ref: cli.tag_ref,
           tag: plan.tag,
           layers: Enum.map(layers, &Map.drop(&1, [:local, :chain])),
           seed: seed_report,
           cli_set: set.set8
         }}
      end
    end
  end

  # The local images a layer left behind (the CLI layer is a chain of them).
  defp chain(%{chain: chain}), do: chain
  defp chain(%{local: local}), do: [local]
  defp chain(_toolchain), do: []

  # `<repo-slug>/worker`: the repo the context names, else the checkout's directory.
  @doc false
  @spec worker_repository(map()) :: String.t()
  def worker_repository(ctx) do
    repo = Map.get(ctx, :repo)
    path = Map.get(ctx, :repo_path)

    RepoConfig.repository_name(
      cond do
        is_binary(repo) and repo != "" -> repo
        is_binary(path) -> Path.basename(path)
        true -> nil
      end
    )
  end

  # One `COPY` per CLI, each `FROM` the one before it, built with a fixed
  # `--timestamp` so identical files give identical layer blobs (SI0, S2). Only
  # the last image is pushed (a push uploads every layer under it); it carries
  # the set's labels and is the run image.
  defp cli_layers(set, parent, tag, repository, work, cfg, opts) do
    last = List.last(set.clis)

    set.clis
    |> Enum.reduce_while({:ok, parent, []}, fn cli, {:ok, from, chain} ->
      local = local_tag("cli-" <> cli.name, tag)

      containerfile =
        "FROM #{from}\n" <>
          "COPY #{Enum.map_join(cli.files, " ", & &1.name)} #{@cli_dest}\n" <>
          if(cli == last, do: label_lines(CliSet.labels(set)), else: "")

      context = Path.join(set.dir, cli.name)

      case build(local, containerfile, context, work, opts, ["--timestamp", @cli_timestamp]) do
        :ok -> {:cont, {:ok, local, [local | chain]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, local, chain} ->
        with {:ok, layer} <- push(local, repository, tag, :cli, cfg, opts) do
          {:ok,
           layer
           |> Map.put(:local, local)
           |> Map.put(:chain, chain)
           |> Map.put(:clis, Enum.map(set.clis, & &1.name))}
        end

      {:error, _} = error ->
        error
    end
  end

  defp label_lines(labels),
    do:
      Enum.map_join(labels, "", fn {k, v} -> "LABEL #{Jason.encode!(k)}=#{Jason.encode!(v)}\n" end)

  @doc """
  The resolved, materialized and re-verified CLI set the layers are built from
  (`Arbiter.Worker.CliSet`), or `{:error, {:cli_unavailable, reason}}`. claude
  is mandatory; codex and arb are in the image when their pins are cached.
  """
  @spec cli_set(keyword()) :: {:ok, CliSet.t()} | {:error, term()}
  def cli_set(opts) do
    with {:ok, set} <- CliSet.resolve(opts),
         :ok <- CliSet.require_cli(set, "claude"),
         {:ok, set} <- CliSet.materialize(set, verify: true) do
      {:ok, set}
    else
      {:error, reason} -> {:error, {:cli_unavailable, reason}}
    end
  end

  @doc false
  @spec cli_files(keyword()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def cli_files(opts) do
    with {:ok, set} <- cli_set(opts) do
      {:ok, Enum.flat_map(set.clis, &CliSet.cli_mounts(set, &1.name))}
    end
  end

  defp seed_layer(ctx, plan, repository, work, cfg, opts) do
    {shipped, excluded} = partition_seed_paths(Map.get(ctx, :seed_paths))

    case seed_mode(plan) do
      :primary ->
        primary_seed(ctx, plan, repository, {shipped, excluded}, work, cfg, opts)

      mode ->
        skipped("seed: #{mode}, #{seed_skip_reason(mode)}", excluded)
    end
  end

  # A prebuilt image says how its deps are seeded (`seed: primary | image | none`);
  # every other image is seeded by the primary.
  defp seed_mode(%{prebuilt: %{seed: mode}}) when mode in [:image, :none], do: mode
  defp seed_mode(_plan), do: :primary

  defp seed_skip_reason(:image), do: "the image already carries /opt/arbiter/seed"
  defp seed_skip_reason(:none), do: "no deps seed (cold compile)"

  defp seed_note(%{prebuilt: %{seed_note: note}}) when is_binary(note), do: note
  defp seed_note(_plan), do: nil

  defp primary_seed(ctx, plan, repository, {shipped, excluded}, work, cfg, opts) do
    case seed_source(ctx, plan, shipped, opts) do
      {:ok, dir, lock_hash, artifacts} ->
        sp8 = artifacts |> Enum.join(",") |> sha256() |> binary_part(0, 8)
        tag = "#{plan.hash}-seed#{binary_part(lock_hash, 0, 12)}-#{sp8}"
        local = local_tag("seed", tag)

        containerfile =
          "FROM #{plan.tag}\n" <>
            Enum.map_join(artifacts, "", fn a -> "COPY #{a}/ #{@seed_dest}/#{a}/\n" end)

        with :ok <- build(local, containerfile, dir, work, opts),
             {:ok, layer} <- push(local, repository, tag, :seed, cfg, opts) do
          {Map.put(layer, :local, local),
           %{status: :pushed, reason: seed_note(plan), excluded: excluded}}
        else
          {:error, reason} -> skipped(reason, excluded)
        end

      {:skip, reason} ->
        skipped(reason, excluded)
    end
  end

  defp skipped(reason, excluded),
    do: {nil, %{status: :skipped, reason: describe(reason), excluded: excluded}}

  defp seed_source(_ctx, _plan, [], _opts),
    do: {:skip, "seed_paths ships nothing from deps/_build"}

  defp seed_source(%{repo_path: repo, base: base}, plan, shipped, opts)
       when is_binary(repo) and is_binary(base) do
    ensure = Keyword.get(opts, :deps_ensure, &DepsCache.ensure/4)

    deps_opts =
      Keyword.take(opts, [:runner, :podman]) ++
        if(opts[:deps_root], do: [root: opts[:deps_root]], else: [])

    case ensure.(repo, base, plan.tag, deps_opts) do
      {:ok, %{dir: dir, lock_hash: lock}} ->
        artifacts = Enum.filter(shipped ++ [@mix_home], &File.dir?(Path.join(dir, &1)))

        if Enum.any?(artifacts, &(&1 in @seed_artifacts)),
          do: {:ok, dir, lock, artifacts},
          else: {:skip, "the deps cache holds no deps/_build"}

      {:error, reason} ->
        {:skip, reason}
    end
  end

  defp seed_source(_ctx, _plan, _shipped, _opts), do: {:skip, "no repository to seed from"}

  @doc """
  Split a resolved `seed_paths` (`nil` = the default set) into the artifacts the
  seed layer ships (`deps`, `_build`, canonical order) and the entries excluded
  (K26), in the order given.
  """
  @spec partition_seed_paths([String.t()] | nil) :: {[String.t()], [String.t()]}
  def partition_seed_paths(nil), do: {@seed_artifacts, []}

  def partition_seed_paths(paths) when is_list(paths) do
    {shipped, excluded} =
      Enum.reduce(paths, {[], []}, fn path, {s, e} ->
        case artifact_of(path) do
          {:ok, head} -> {[head | s], e}
          :error -> {s, [path | e]}
        end
      end)

    {Enum.filter(@seed_artifacts, &(&1 in shipped)), Enum.reverse(excluded)}
  end

  defp artifact_of(path) when is_binary(path) do
    normalized = path |> String.trim() |> String.trim_leading("./") |> String.trim_trailing("/")
    segments = Path.split(normalized)

    cond do
      normalized == "" -> :error
      Path.type(normalized) == :absolute -> :error
      ".." in segments or "." in segments -> :error
      hd(segments) in @seed_artifacts -> {:ok, hd(segments)}
      true -> :error
    end
  end

  defp artifact_of(_), do: :error

  # -- the controller image -----------------------------------------------------

  @doc """
  Build the controller image from the retained release tarball and push it as
  `<registry>/controller:<version>` (§11): `FROM <pinned public glibc base>`,
  unpack to `/opt/arbiter`, run as uid 10001, `ENTRYPOINT [bin/arbiter, start]`.
  """
  @spec publish_controller(Registry.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def publish_controller(%Registry{} = cfg, opts) do
    artifact = Keyword.get_lazy(opts, :artifact, fn -> Agent.artifact() end)
    resolver = Keyword.get_lazy(opts, :resolver, fn -> Pins.resolver(opts) end)

    with {:ok, %{version: version, path: tarball}} <- release(artifact),
         {:ok, text, _pins} <- Image.pin(controller_containerfile(), resolver) do
      tag = Regex.replace(~r/[^A-Za-z0-9_.-]/, version, "_")

      workdir(opts, fn work ->
        context = Path.join(work, "controller-context")
        File.mkdir_p!(context)
        File.cp!(tarball, Path.join(context, "release.tar.gz"))
        local = local_tag("controller", tag)

        with :ok <- build(local, text, context, work, opts),
             {:ok, layer} <- push(local, "controller", tag, :controller, cfg, opts) do
          cleanup_local([local], opts)

          {:ok,
           %{
             ref: layer.ref,
             tag_ref: layer.tag_ref,
             tag: tag,
             layers: [Map.delete(layer, :local)],
             seed: %{status: :skipped, reason: nil, excluded: []}
           }}
        end
      end)
    else
      {:error, {:unpinned_base, _, _} = reason} -> {:error, {:controller_base, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp release({:ok, %{version: _, path: _} = artifact}), do: {:ok, artifact}
  defp release({:error, reason}), do: {:error, {:no_release, reason}}

  @doc """
  The (unpinned) controller Containerfile; `Image.pin/2` pins its `FROM`. `socat` is there
  for the NetworkPolicy canary (K14): before any worker image has been published, the
  canary pod runs this image (`ClusterInstall.controller_facts/1`), and its probes and the
  netpol gate are `sh` + `socat`.
  """
  @spec controller_containerfile() :: String.t()
  def controller_containerfile do
    """
    #{@controller_base}
    RUN apt-get update \\
     && apt-get install -y --no-install-recommends ca-certificates libstdc++6 libncurses6 openssl socat \\
     && rm -rf /var/lib/apt/lists/* \\
     && groupadd --gid #{@controller_uid} arbiter \\
     && useradd --uid #{@controller_uid} --gid #{@controller_uid} --create-home arbiter
    ADD release.tar.gz /opt/
    USER #{@controller_uid}
    ENTRYPOINT ["/opt/arbiter/bin/arbiter", "start"]
    """
  end

  # -- podman -------------------------------------------------------------------

  defp build(tag, containerfile, context, work, opts, extra \\ []) do
    file = Path.join(work, "Containerfile.#{short(tag)}")
    File.write!(file, containerfile)

    args =
      [
        "build",
        "--file",
        file,
        "--tag",
        tag,
        "--label",
        "#{Image.label()}.publish=1"
      ] ++ extra ++ [context]

    case podman(args, opts, @build_timeout_ms) do
      {_, 0} -> :ok
      {out, status} -> {:error, {:build_failed, tag, status, tail(out)}}
    end
  end

  # Tag the local image for the registry, push it (credentials by auth file),
  # and read the digest podman wrote.
  defp push(local, repo_name, tag, layer, cfg, opts) do
    remote = Registry.repository(cfg, repo_name) <> ":" <> tag

    Registry.with_authfile(cfg, scratch(opts), fn authfile ->
      workdir(opts, fn work ->
        digestfile = Path.join(work, "digest")

        args =
          ["push", "--digestfile", digestfile] ++
            Registry.tls_flags(cfg) ++
            if(authfile, do: ["--authfile", authfile], else: []) ++ [remote]

        with {_, 0} <- tag_for_registry(local, remote, opts),
             {_out, 0} <- podman(args, opts, @push_timeout_ms) |> guard(:push_failed, remote, cfg),
             {:ok, digest} <- read_digest(digestfile, remote) do
          _ = podman(["untag", local, remote], opts, @quick_timeout_ms)

          {:ok,
           %{
             layer: layer,
             tag: tag,
             tag_ref: remote,
             digest: digest,
             ref: Registry.repository(cfg, repo_name) <> "@" <> digest
           }}
        else
          {:error, _} = error ->
            error

          {out, status} ->
            {:error, {:tag_failed, remote, status, tail(Registry.redact(out, cfg))}}
        end
      end)
    end)
  end

  # The CI image, into local storage by digest, so the overlay builds and
  # `DepsCache` runs read it from there. Its host's login (the repo's registry
  # credential, when the hosts match) is the auth file, never argv.
  defp pull(ref, cfg, opts) do
    Registry.with_authfile(cfg, scratch(opts), fn authfile ->
      args =
        ["pull", "--quiet"] ++
          Registry.tls_flags(cfg) ++ if(authfile, do: ["--authfile", authfile], else: []) ++ [ref]

      case podman(args, opts, @push_timeout_ms) do
        {_, 0} -> :ok
        {out, status} -> {:error, {:pull_failed, ref, status, tail(Registry.redact(out, cfg))}}
      end
    end)
  end

  defp tag_for_registry(local, remote, opts),
    do: podman(["tag", local, remote], opts, @quick_timeout_ms)

  defp guard({out, 0}, _kind, _remote, _cfg), do: {out, 0}

  defp guard({out, status}, kind, remote, cfg),
    do: {:error, {kind, remote, status, tail(Registry.redact(out, cfg))}}

  defp read_digest(path, remote) do
    with {:ok, body} <- File.read(path),
         digest = String.trim(body),
         true <- Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, digest) do
      {:ok, digest}
    else
      _ -> {:error, {:no_digest, remote}}
    end
  end

  defp cleanup_local(tags, opts) do
    Enum.each(tags, &podman(["rmi", "--ignore", &1], opts, @quick_timeout_ms))
  end

  defp podman(args, opts, timeout),
    do: Image.run("podman", args, [timeout: timeout] ++ Keyword.take(opts, [:runner]))

  # -- helpers ------------------------------------------------------------------

  defp scratch(opts),
    do: Keyword.get_lazy(opts, :scratch, fn -> Path.join(Paths.scratch_root(), "images") end)

  defp workdir(opts, fun) do
    root = scratch(opts)
    File.mkdir_p!(root)

    dir =
      Path.join(
        root,
        "publish-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"
      )

    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf(dir)
    end
  end

  defp local_tag(kind, tag), do: "#{Image.registry()}/publish-#{kind}:#{tag}"

  defp short(tag), do: tag |> sha256() |> binary_part(0, 12)

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp tail(output) do
    output = String.trim(output)
    String.slice(output, max(String.length(output) - 1_500, 0), 1_500)
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
