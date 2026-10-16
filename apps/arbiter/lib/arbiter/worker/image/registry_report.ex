defmodule Arbiter.Worker.Image.RegistryReport do
  @moduledoc """
  Every registry the primary pushes images to, as the doctor reports it (KH12,
  `docs/design/remote-workers.md` §20.10): the install-wide `nodes.registry` and
  each distinct `worker.image.registry` / `worker.repos.<repo>.image.registry` the
  workspaces name, one entry per registry with

    * `repositories` — the `<repo-slug>/worker` repositories that land there
      (plus `controller` on the install registry),
    * `reachable` — `GET /v2/`,
    * `anonymous` — per repository, `public` / `private` / `unknown`
      (`Registry.anonymous_read/3`), and `public` listing the readable ones,
    * `credentials` — `set`, `anonymous` (no `credentials_ref`) or `error: …`
      (the secret is missing or not `user:password`).

  Never a password. A repo that resolves to no registry is not listed.

  Options: `:workspaces` (default: all), `:config` (install registry, as
  `Registry.fetch/1`), `:probe` (`(Registry.t -> :ok | {:error, term})`),
  `:anonymous_probe` (`(Registry.t, repository -> :public | :private | {:unknown, term})`).
  """

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Image.Registry
  alias Arbiter.Worker.Image.RepoConfig

  @probe_concurrency 4
  @probe_timeout_ms 15_000

  @type entry :: %{optional(atom()) => term()}

  @spec build(keyword()) :: [entry()]
  def build(opts \\ []) do
    opts
    |> groups()
    |> Enum.map(&report(&1, opts))
  end

  # %{registry => %{cfg:, origin:, repositories:, credentials:}}, install first.
  defp groups(opts) do
    install = Registry.fetch(opts)

    seed =
      case install do
        {:ok, cfg} ->
          %{cfg.registry => group(cfg, "install", ["controller"], credentials(cfg))}

        :unset ->
          %{}
      end

    opts
    |> workspaces()
    |> Enum.reduce(seed, fn workspace, acc ->
      workspace |> repos() |> Enum.reduce(acc, &add_repo(&2, workspace, &1, opts))
    end)
    |> Map.values()
    |> Enum.sort_by(&{&1.origin != "install", &1.registry})
  end

  defp workspaces(opts), do: Keyword.get_lazy(opts, :workspaces, fn -> Ash.read!(Workspace) end)

  @doc false
  @spec repos(map()) :: [String.t()]
  def repos(workspace) do
    config = workspace.config || %{}
    paths = if is_map(config["repo_paths"]), do: Map.keys(config["repo_paths"]), else: []
    worker = config["worker"]
    own = if is_map(worker) and is_map(worker["repos"]), do: Map.keys(worker["repos"]), else: []
    Enum.uniq(paths ++ own)
  end

  defp add_repo(acc, workspace, repo, opts) do
    case Registry.resolve(workspace, repo, opts) do
      {:ok, cfg} ->
        merge(acc, cfg, RepoConfig.repository_name(repo), credentials(cfg))

      {:error, {:registry_credentials, ref, reason}} ->
        %{registry: registry} = RepoConfig.resolve(workspace, repo)

        cfg = %Registry{
          registry: registry,
          host: registry |> String.split("/") |> hd(),
          origin: :config
        }

        merge(acc, cfg, RepoConfig.repository_name(repo), "error: #{ref} #{reason}")

      :unset ->
        acc
    end
  end

  defp credentials(%{username: user, password: pw}),
    do: if(user && pw, do: "set", else: "anonymous")

  defp merge(acc, cfg, repository, credentials) do
    Map.update(
      acc,
      cfg.registry,
      group(cfg, origin_name(cfg), [repository], credentials),
      fn existing ->
        %{
          existing
          | repositories: Enum.uniq(existing.repositories ++ [repository]),
            public_ok: existing.public_ok or cfg.public_ok,
            credentials: worst(existing.credentials, credentials)
        }
      end
    )
  end

  defp group(cfg, origin, repositories, credentials),
    do: %{
      registry: cfg.registry,
      cfg: cfg,
      origin: origin,
      repositories: repositories,
      public_ok: cfg.public_ok,
      credentials: credentials
    }

  defp origin_name(%{origin: :install}), do: "install"
  defp origin_name(_), do: "config"

  defp worst("error" <> _ = error, _), do: error
  defp worst(_, "error" <> _ = error), do: error
  defp worst(a, _), do: a

  defp report(group, opts) do
    {reachable, detail} =
      case probe(opts).(group.cfg) do
        :ok -> {true, nil}
        {:error, reason} -> {false, inspect(reason)}
      end

    anonymous = anonymous(group, opts)

    %{
      registry: group.registry,
      origin: group.origin,
      repositories: group.repositories,
      credentials: group.credentials,
      public_ok: group.public_ok,
      reachable: reachable,
      reachable_detail: detail,
      anonymous: anonymous,
      public: for({repo, "public"} <- anonymous, do: repo) |> Enum.sort()
    }
  end

  # Only a reachable registry is asked; an unreachable one would time out per repository.
  defp anonymous(group, opts) do
    anon = Keyword.get(opts, :anonymous_probe, &Registry.anonymous_read/2)

    group.repositories
    |> Task.async_stream(
      fn repo -> {repo, answer(anon.(group.cfg, repo))} end,
      max_concurrency: @probe_concurrency,
      timeout: @probe_timeout_ms,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Map.new(fn
      {:ok, pair} -> pair
      {:exit, {repo, _reason}} -> {repo, "unknown"}
    end)
  end

  defp answer(:public), do: "public"
  defp answer(:private), do: "private"
  defp answer(_), do: "unknown"

  defp probe(opts), do: Keyword.get(opts, :probe, &Registry.reachable/1)
end
