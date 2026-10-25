defmodule Arbiter.Worker.Image.Prebuilt do
  @moduledoc """
  The `prebuilt` image source (KH14, `docs/design/remote-workers.md` §20.9, OD4
  and OD10): an image the repo's own CI builds, named by the operator's
  `worker.repos.<repo>.image.ref`. The primary does not build it; it **trusts**
  it only after three checks, and then overlays the CLI (and, per `seed`, the
  seed) layer onto it (`Arbiter.Worker.Image.Publisher.Pipeline`).

    1. **Tag to digest.** `ref` (a moving tag, or already `@sha256:…`) is resolved
       with `skopeo inspect` (`podman pull` + `image inspect` when skopeo is not
       installed) and the plan is pinned on the digest: every build and every pod
       uses it, so the tag moving later changes nothing already handed out. The
       answer is cached for #{div(300_000, 60_000)} minutes (`:cache_ttl_ms`).
    2. **Runtime contract.** The image must carry the label
       `arbiter.runtime-contract=1`: it was built `FROM
       ghcr.io/<owner>/arbiter-worker-base:<hash>` and so has `tini`, `socat`,
       uid 10001 and the rest of what the pod runtime needs. A missing item is
       `{:contract_mismatch, "<what is missing>"}`.
    3. **Revision on the default branch.** The label
       `org.opencontainers.image.revision` must be a commit that is an
       **ancestor of the default branch tip** in the primary's clone
       (`git merge-base --is-ancestor`, against `refs/remotes/origin/<default>`
       else `refs/heads/<default>`, never `HEAD`). A CI job on a feature branch
       that pushes the trusted tag is therefore refused:
       `{:prebuilt_not_on_default, %{revision:, branch:}}`. This check runs on
       every plan; only the registry answer is cached.

  `seed: image` additionally compares the label `arbiter.seed-lock` (the sha256
  of the `mix.lock` CI seeded from) with the default branch's `mix.lock`; a
  mismatch or a missing label falls back to `seed: primary` and the plan's
  `prebuilt.seed_note` says why (a stale seed is a slow run, not a wrong one).

  ## Repo-CI contract: no credential in a layer (SI12)

  The image reaches every worker, so the repo's CI must pass credentials only through
  build-secret mounts (`RUN --mount=type=secret,id=…`), never `ARG` or `ENV`: an `ARG`
  used in a `RUN` is recorded in clear in the image history. For **every** `prebuilt`
  plan the image config's `Env` and each history `created_by` are scanned for the
  values the workspace hands a worker (`:secret_values`) and for credential-shaped
  tokens (`Arbiter.Redaction.redact_patterns/1`); a hit refuses the image for every run
  (`{:secret_in_image, where}`, surfaced as `image_unavailable`). For `seed: image` the
  image's `/opt/arbiter/seed` is also inspected (`Arbiter.Worker.Image.SeedScan`): no
  `hex.config`, `.netrc`, `.git-credentials`, SSH private key or private-key `.pem`, and no
  `deps/*/.git/config` remote URL with userinfo; an image that cannot be inspected is
  seeded by the primary instead. Options: `:secret_values`, `:seed_inspector`.

  Credentials: the repo's resolved registry login (`Registry.resolve/3`,
  `credentials_ref`) is the credential to read `ref` too, passed to skopeo as a
  0600 auth file, never argv. A `ref` on a different host than the push registry
  is read anonymously unless that registry shares the host.

  Options: `:image` (`Arbiter.Worker.Image.RepoConfig.t()`), `:registry`
  (`Registry.t()` or `nil`), `:runner` (see `Image.run/3`), `:scratch`,
  `:cache_ttl_ms`, `:repo_name`.
  """

  alias Arbiter.Config.Paths
  alias Arbiter.Mergers
  alias Arbiter.Mergers.LocalCompare
  alias Arbiter.Redaction
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Image
  alias Arbiter.Worker.Image.Registry
  alias Arbiter.Worker.Image.RegistryReport
  alias Arbiter.Worker.Image.RepoConfig
  alias Arbiter.Worker.Image.SeedScan

  {contract_label, contract_version} = Image.contract_label()
  @contract_label contract_label
  @contract_version contract_version
  @revision_label "org.opencontainers.image.revision"
  @seed_lock_label "arbiter.seed-lock"
  @commit_re ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @cache_ttl_ms 300_000
  @inspect_timeout_ms 120_000
  # A shorter value (`true`, `1`) is a flag, not a credential; matching it would refuse every image.
  @min_secret_bytes 8

  @type plan :: map()

  @doc "The label holding the sha256 of the `mix.lock` an image's `/opt/arbiter/seed` was built from."
  @spec seed_lock_label() :: String.t()
  def seed_lock_label, do: @seed_lock_label

  @doc """
  The plan for `repo_path`'s prebuilt image, trusted per the moduledoc, or the
  refusal: `{:source_unavailable, :prebuilt, message}`, `{:prebuilt_unresolvable,
  ref, reason}`, `{:contract_mismatch, missing}`,
  `{:prebuilt_not_on_default, %{revision:, branch:}}`, or a default-branch error
  from `Image.default_ref/2`.

  The plan has `Image.plan/3`'s shape with `source: :prebuilt`, `tag` the
  digest-pinned CI reference, `containerfile` a single `FROM` of it, no `base`,
  and `prebuilt: %{ref:, digest:, revision:, seed:, seed_note:}`.
  """
  @spec plan(String.t(), String.t(), keyword()) :: {:ok, plan()} | {:error, term()}
  def plan(repo_path, default_branch, opts) when is_binary(repo_path) do
    image = Keyword.get(opts, :image) || %{}

    with {:ok, ref} <- require_ref(image),
         {:ok, git_ref} <- Image.default_ref(repo_path, default_branch),
         {:ok, info} <- inspect_ref(ref, opts),
         :ok <- verify_no_secrets(info, opts),
         :ok <- verify_contract(info.labels),
         {:ok, revision} <- revision(info.labels),
         :ok <- verify_ancestor(repo_path, git_ref, default_branch, revision) do
      {seed, note} = seed(Map.get(image, :seed, :primary), info.labels, repo_path, git_ref)

      with {:ok, seed, note} <- verify_seed(seed, note, ref, info.digest, opts) do
        {:ok, build_plan(ref, info.digest, revision, seed, note, git_ref, opts)}
      end
    end
  end

  defp require_ref(%{ref: ref}) when is_binary(ref) and ref != "", do: {:ok, ref}

  defp require_ref(_),
    do: {:error, {:source_unavailable, :prebuilt, "worker.repos.<repo>.image.ref is not set"}}

  defp build_plan(ref, digest, revision, seed, note, git_ref, opts) do
    pinned = repository(ref) <> "@" <> digest
    name = "prebuilt-" <> Image.slug(Keyword.get(opts, :repo_name) || "custom")

    %{
      name: name,
      hash: hash([digest, to_string(seed)]),
      tag: pinned,
      containerfile: "FROM #{pinned}\n",
      build_args: [],
      source: :prebuilt,
      ref: git_ref,
      toolchain: nil,
      pins: [{ref, digest}],
      base: nil,
      prebuilt: %{ref: ref, digest: digest, revision: revision, seed: seed, seed_note: note}
    }
  end

  defp hash(parts) do
    parts
    |> Enum.intersperse(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  # `host:5000/a/b:tag@sha256:…` → `host:5000/a/b`.
  defp repository(ref) do
    [name | _] = String.split(ref, "@", parts: 2)

    case String.split(name, "/") |> List.last() |> String.split(":", parts: 2) do
      [_, tag] -> binary_part(name, 0, byte_size(name) - byte_size(tag) - 1)
      _ -> name
    end
  end

  # -- contract and ancestry --------------------------------------------------------

  # SI12: a credential in the image config's `Env` or in any layer's `created_by` is in
  # every run's image, so it refuses the image for every run, whatever `seed` is.
  # Matches the values `WorkerEnv` knows (`:secret_values`) and credential-shaped tokens.
  defp verify_no_secrets(info, opts) do
    values =
      opts
      |> Keyword.get(:secret_values, [])
      |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= @min_secret_bytes))

    leaked = fn entries -> Enum.any?(entries, &secret?(&1, values)) end

    cond do
      leaked.(Map.get(info, :env, [])) -> {:error, {:secret_in_image, "the image config's Env"}}
      leaked.(Map.get(info, :history, [])) -> {:error, {:secret_in_image, "the image history"}}
      true -> :ok
    end
  end

  defp secret?(text, values),
    do: Redaction.redact(Redaction.redact_patterns(text), values) != text

  defp verify_contract(labels) do
    case labels[@contract_label] do
      @contract_version ->
        :ok

      nil ->
        {:error,
         {:contract_mismatch,
          "label #{@contract_label}=#{@contract_version} is missing (build the image " <>
            "FROM ghcr.io/<owner>/arbiter-worker-base and set it)"}}

      other ->
        {:error,
         {:contract_mismatch,
          "label #{@contract_label} is #{inspect(other)}, this primary needs #{@contract_version}"}}
    end
  end

  defp revision(labels) do
    case labels[@revision_label] do
      rev when is_binary(rev) ->
        if Regex.match?(@commit_re, rev),
          do: {:ok, rev},
          else:
            {:error,
             {:contract_mismatch,
              "label #{@revision_label} is not a full commit id: #{inspect(String.slice(rev, 0, 80))}"}}

      _ ->
        {:error, {:contract_mismatch, "label #{@revision_label} is missing"}}
    end
  end

  defp verify_ancestor(repo_path, git_ref, branch, revision) do
    case Image.git(repo_path, ["merge-base", "--is-ancestor", revision, git_ref]) do
      {_, 0} -> :ok
      _ -> {:error, {:prebuilt_not_on_default, %{revision: revision, branch: branch}}}
    end
  end

  # -- seed ----------------------------------------------------------------------

  defp seed(:image, labels, repo_path, git_ref) do
    have = labels[@seed_lock_label]

    case {have, lock_hash(repo_path, git_ref)} do
      {nil, _} ->
        {:primary, "image has no #{@seed_lock_label} label: the primary seeds deps instead"}

      {_, nil} ->
        {:primary,
         "no mix.lock on the default branch to match #{@seed_lock_label}: seeding on the primary"}

      {same, same} ->
        {:image, nil}

      {_, want} ->
        {:primary,
         "#{@seed_lock_label} does not match the default branch's mix.lock " <>
           "(#{String.slice(want, 0, 12)}): the primary seeds deps instead"}
    end
  end

  defp seed(mode, _labels, _repo_path, _git_ref), do: {mode, nil}

  # SI12: an image seed is trusted only if `/opt/arbiter/seed` holds no credential
  # (`SeedScan`). A hit refuses the image; an image that cannot be inspected is not
  # trusted for its seed and the primary seeds instead. `opts[:seed_inspector]`
  # (`pinned_ref -> {:ok, output} | {:error, reason}`) replaces the `podman run`.
  defp verify_seed(:image, note, ref, digest, opts) do
    pinned = repository(ref) <> "@" <> digest
    inspector = Keyword.get(opts, :seed_inspector) || (&inspect_seed(&1, opts))
    ttl = Keyword.get(opts, :cache_ttl_ms, @cache_ttl_ms)
    key = {__MODULE__, :seed_scan, digest}

    case scan_seed(inspector, pinned, key, ttl) do
      :ok ->
        {:ok, :image, note}

      {:error, hits} ->
        {:error, {:secret_in_image, "/opt/arbiter/seed: " <> describe_hits(hits)}}

      {:uninspectable, reason} ->
        {:ok, :primary,
         "could not inspect the image's /opt/arbiter/seed (#{inspect(reason)}): " <>
           "the primary seeds deps instead"}
    end
  end

  defp verify_seed(seed, note, _ref, _digest, _opts), do: {:ok, seed, note}

  defp scan_seed(inspector, pinned, key, ttl) do
    case cached(key, ttl) do
      {:ok, result} ->
        result

      :miss ->
        result =
          case inspector.(pinned) do
            {:ok, out} -> SeedScan.check(out)
            {:error, reason} -> {:uninspectable, reason}
          end

        # A digest is immutable, so a verdict is kept; a failed inspection is retried.
        if match?({:uninspectable, _}, result), do: :ok, else: store(key, result, ttl)
        result
    end
  end

  defp describe_hits(hits) do
    Enum.map_join(hits, ", ", fn
      {:credential_file, path} -> "credential file #{path}"
      {:userinfo_url, path} -> "remote URL with userinfo in #{path}"
    end)
  end

  defp inspect_seed(pinned, opts) do
    cfg = Keyword.get(opts, :registry)

    scratch =
      Keyword.get_lazy(opts, :scratch, fn -> Path.join(Paths.scratch_root(), "images") end)

    Registry.with_authfile(List.wrap(cfg), scratch, fn authfile ->
      flags = tls(cfg) ++ if(authfile, do: ["--authfile", authfile], else: [])

      args =
        ["run", "--rm", "--network=none", "--read-only", "--cap-drop=all", "--pull=missing"] ++
          flags ++ ["--entrypoint", "sh", pinned, "-c", SeedScan.script()]

      case Image.run(
             "podman",
             args,
             Keyword.take(opts, [:runner]) ++ [timeout: @inspect_timeout_ms]
           ) do
        {out, 0} -> {:ok, out}
        {out, status} -> {:error, "podman exited #{status}: #{reason(out, cfg)}"}
      end
    end)
  end

  defp lock_hash(repo_path, git_ref) do
    case Image.git(repo_path, ["cat-file", "blob", "#{git_ref}:mix.lock"]) do
      {body, 0} -> :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      _ -> nil
    end
  end

  # -- resolving the reference -------------------------------------------------------

  defp inspect_ref(ref, opts) do
    ttl = Keyword.get(opts, :cache_ttl_ms, @cache_ttl_ms)
    key = {__MODULE__, ref, host_of(Keyword.get(opts, :registry))}

    case cached(key, ttl) do
      {:ok, info} ->
        {:ok, info}

      :miss ->
        with {:ok, info} <- fetch(ref, opts) do
          store(key, info, ttl)
          {:ok, info}
        end
    end
  end

  defp host_of(%Registry{host: host}), do: host
  defp host_of(_), do: nil

  defp cached(_key, ttl) when ttl <= 0, do: :miss

  defp cached(key, _ttl) do
    case :persistent_term.get(key, nil) do
      {expires, info} ->
        if System.monotonic_time(:millisecond) < expires, do: {:ok, info}, else: :miss

      nil ->
        :miss
    end
  end

  defp store(_key, _info, ttl) when ttl <= 0, do: :ok

  defp store(key, info, ttl),
    do: :persistent_term.put(key, {System.monotonic_time(:millisecond) + ttl, info})

  defp fetch(ref, opts) do
    cfg = Keyword.get(opts, :registry)

    scratch =
      Keyword.get_lazy(opts, :scratch, fn -> Path.join(Paths.scratch_root(), "images") end)

    run_opts = Keyword.take(opts, [:runner]) ++ [timeout: @inspect_timeout_ms]

    Registry.with_authfile(List.wrap(cfg), scratch, fn authfile ->
      flags = tls(cfg) ++ if(authfile, do: ["--authfile", authfile], else: [])

      result =
        case Image.run(
               "skopeo",
               ["inspect", "--no-tags"] ++ flags ++ ["docker://" <> ref],
               run_opts
             ) do
          {out, 0} ->
            with {:ok, info} <- parse_skopeo(out), do: add_config(info, ref, flags, run_opts)

          {_, 127} ->
            with_podman(ref, flags, run_opts)

          {out, _} ->
            {:error, out}
        end

      case result do
        {:ok, info} -> check_digest(ref, info)
        {:error, out} -> {:error, {:prebuilt_unresolvable, ref, reason(out, cfg)}}
      end
    end)
  end

  defp tls(%Registry{} = cfg), do: Registry.tls_flags(cfg)
  defp tls(_), do: []

  defp with_podman(ref, flags, run_opts) do
    with {_, 0} <- Image.run("podman", ["pull", "--quiet"] ++ flags ++ [ref], run_opts),
         {out, 0} <- Image.run("podman", ["image", "inspect", ref], run_opts) do
      parse_podman(out)
    else
      {out, status} -> {:error, "podman exited #{status}: #{out}"}
    end
  end

  defp parse_skopeo(out) do
    case Jason.decode(out) do
      {:ok, %{"Digest" => digest} = body} ->
        {:ok,
         %{digest: digest, labels: labels(body["Labels"]), env: strings(body["Env"]), history: []}}

      _ ->
        {:error, "skopeo inspect returned unparsable output"}
    end
  end

  defp parse_podman(out) do
    case Jason.decode(out) do
      {:ok, [%{"Digest" => digest} = body | _]} ->
        {:ok,
         %{
           digest: digest,
           labels: labels(body["Labels"] || get_in(body, ["Config", "Labels"])),
           env: strings(get_in(body, ["Config", "Env"])),
           history: created_by(body["History"])
         }}

      _ ->
        {:error, "podman image inspect returned unparsable output"}
    end
  end

  # skopeo's plain `inspect` has no history; `--config` is the image config itself.
  defp add_config(info, ref, flags, run_opts) do
    case Image.run(
           "skopeo",
           ["inspect", "--config", "--no-tags"] ++ flags ++ ["docker://" <> ref],
           run_opts
         ) do
      {out, 0} ->
        case Jason.decode(out) do
          {:ok, %{} = config} ->
            {:ok,
             %{
               info
               | env: info.env ++ strings(get_in(config, ["config", "Env"])),
                 history: created_by(config["history"])
             }}

          _ ->
            {:error, "skopeo inspect --config returned unparsable output"}
        end

      {out, _} ->
        {:error, out}
    end
  end

  defp strings(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp strings(_), do: []

  defp created_by(list) when is_list(list),
    do: for(%{"created_by" => cmd} <- list, is_binary(cmd), do: cmd)

  defp created_by(_), do: []

  defp labels(%{} = labels), do: labels
  defp labels(_), do: %{}

  # A digest-pinned `ref` must come back as that digest.
  defp check_digest(ref, %{digest: digest} = info) do
    pinned = ref |> String.split("@", parts: 2) |> Enum.at(1)

    cond do
      not Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, digest) ->
        {:error, {:prebuilt_unresolvable, ref, "not a sha256 digest: #{inspect(digest)}"}}

      pinned && pinned != digest ->
        {:error,
         {:prebuilt_unresolvable, ref, "registry answered #{digest}, not the pinned digest"}}

      true ->
        {:ok, info}
    end
  end

  defp reason(out, cfg) do
    out |> Registry.redact(List.wrap(cfg)) |> String.trim() |> String.slice(0, 300)
  end

  # -- the doctor ------------------------------------------------------------------

  @doc """
  What the doctor shows for a repo whose `image.source` is `prebuilt` (no run is
  started): `%{status: :ok | :error, ref:, digest:, revision:, seed:, seed_note:,
  error:}`. Takes `plan/3`'s options.
  """
  @spec check(String.t(), String.t(), map(), keyword()) :: map()
  def check(repo_path, default_branch, image, opts \\ []) do
    base = %{ref: Map.get(image, :ref), digest: nil, revision: nil, seed: nil, seed_note: nil}

    case plan(repo_path, default_branch, Keyword.put(opts, :image, image)) do
      {:ok, %{prebuilt: prebuilt}} ->
        base
        |> Map.merge(Map.take(prebuilt, [:digest, :revision, :seed, :seed_note]))
        |> Map.merge(%{status: :ok, error: nil})

      {:error, reason} ->
        Map.merge(base, %{status: :error, error: describe(reason)})
    end
  end

  @doc """
  The doctor's `image` rows (`GET /api/nodes` → `registry.images`): one JSON-ready
  map per repo, in any workspace, whose `image.source` is `prebuilt`, from `check/4`
  against the repo's registered checkout. Options: `:workspaces` (default all),
  plus `plan/3`'s.
  """
  @spec report(keyword()) :: [map()]
  def report(opts \\ []) do
    opts
    |> workspaces()
    |> Enum.flat_map(fn workspace ->
      for repo <- RegistryReport.repos(workspace),
          %{source: :prebuilt} = image <- [RepoConfig.resolve(workspace, repo)],
          do: {workspace, repo, image}
    end)
    |> Task.async_stream(
      fn {workspace, repo, image} -> row(workspace, repo, image, opts) end,
      max_concurrency: 4,
      timeout: @inspect_timeout_ms + 10_000,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.map(fn
      {:ok, row} -> row
      {:exit, {{workspace, repo, image}, _}} -> failed_row(workspace, repo, image, "timed out")
    end)
  end

  defp workspaces(opts), do: Keyword.get_lazy(opts, :workspaces, fn -> Ash.read!(Workspace) end)

  defp row(workspace, repo, image, opts) do
    result =
      with path when is_binary(path) <- LocalCompare.repo_path(workspace, repo),
           {:ok, registry} <- report_registry(workspace, repo, opts) do
        branch = Mergers.base_branch(workspace, repo) || "main"
        check(path, branch, image, Keyword.merge(opts, registry: registry, repo_name: repo))
      else
        nil -> failed(image, "repo #{inspect(repo)} is not registered (see `arb repo list`)")
        {:error, reason} -> failed(image, reason)
      end

    to_row(workspace, repo, result)
  end

  defp failed_row(workspace, repo, image, error),
    do: to_row(workspace, repo, failed(image, error))

  defp to_row(workspace, repo, result) do
    result
    |> Map.merge(%{workspace: workspace.name, repo: repo})
    |> Map.update!(:status, &Atom.to_string/1)
    |> Map.update!(:seed, &seed_name/1)
  end

  defp failed(image, error),
    do: %{
      status: :error,
      ref: Map.get(image, :ref),
      digest: nil,
      revision: nil,
      seed: nil,
      seed_note: nil,
      error: error
    }

  defp seed_name(nil), do: nil
  defp seed_name(seed), do: Atom.to_string(seed)

  # The repo's registry login also reads its `ref`; an unusable credential is the row's error.
  defp report_registry(workspace, repo, opts) do
    case Registry.resolve(workspace, repo, Keyword.take(opts, [:config])) do
      {:ok, cfg} ->
        {:ok, cfg}

      :unset ->
        {:ok, nil}

      {:error, {:registry_credentials, ref, reason}} ->
        {:error, "credential #{ref} unusable (#{reason})"}
    end
  end

  @doc "A refusal from `plan/3`, as one line for the doctor and the logs."
  @spec describe(term()) :: String.t()
  def describe({:prebuilt_not_on_default, %{revision: revision, branch: branch}}),
    do:
      "revision #{String.slice(revision, 0, 12)} is not an ancestor of the tip of #{branch}: " <>
        "CI built it from a commit that is not merged"

  def describe({:contract_mismatch, missing}), do: "runtime contract not met: #{missing}"

  def describe({:prebuilt_unresolvable, ref, reason}), do: "cannot resolve #{ref}: #{reason}"
  def describe({:source_unavailable, _source, message}), do: message

  def describe({:no_default_branch, branch}),
    do: "no default branch #{inspect(branch)} in the clone"

  def describe(other), do: inspect(other)
end
