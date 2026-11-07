defmodule Arbiter.Worker.GitCredential.GitlabBot do
  @moduledoc """
  The `gitlab_bot_token` credential's dispatch guard and expiry report (bd-8ufzng).

  GitLab project access tokens (`gitlab_project_token`) are a Premium/Ultimate
  feature. On a Free group the operator instead creates a **bot user** whose only
  memberships are Developer on the target projects, and gives Arbiter that user's
  personal access token (`read_api`, `read_repository`, `write_repository`, with
  an expiry). The PAT is limited to those projects *by membership*, not by
  construction, so Arbiter checks it before every delivery:

    * `GET /personal_access_tokens/self` — the token is active, carries only
      `read_api` / `read_repository` / `write_repository` (so never `api` or
      `sudo`) and has an expiry that has not passed;
    * `GET /projects?membership=true` — the projects the bot reaches are exactly
      the configured ones: the spawn's own project, the entry's `projects`, and the
      `remote` / `projects` of sibling `gitlab_bot_token` entries that name the same
      secret and host. Anything wider refuses the spawn.

  A **fine-grained** personal access token (bd-8h80lm) is recognised by the
  `granular_scopes` list `personal_access_tokens/self` returns instead of `scopes`.
  Its own resource list, not the bot's membership, is the boundary then (membership
  is typically wider: the bot is a member of whole groups):

    * every `granular_scopes` entry must be `access: "selected_memberships"` naming
      one `project_id`; a group, `all_memberships`, `personal_projects`, `user` or
      `instance` entry is not a project list and refuses;
    * the `permissions` across entries must be within `allowed_granular_permissions/0`;
    * the project ids are resolved to paths through
      `GET /personal_access_tokens/self/associations`, and the paths must be exactly
      the configured projects (same rule as membership above).

  The fine-grained response shape (`granular_scopes`, `/self/associations`) is from
  GitLab's API reference; the permission identifiers for Git push and download are
  not documented there, so `allowed_granular_permissions/0` is an unverified
  assumption: if it is wrong the guard refuses (naming the permissions it saw)
  rather than passes.

  Every check fails closed: an answer that cannot be read is a refusal, never a
  delivery. Nothing here logs or returns the token.
  """

  alias Arbiter.Tasks.Workspace

  @allowed_scopes ~w(read_api read_repository write_repository)
  # UNVERIFIED (bd-8h80lm): GitLab's UI calls these "Code: Download" and "Code: Push",
  # but its API reference does not list the identifiers. Capture a redacted
  # `granular_scopes` of the real bot token and correct this list; until then a wrong
  # name only makes the guard refuse.
  @allowed_granular_permissions ~w(download_code push_code)
  @per_page 100
  @max_pages 20
  @warn_days 14

  @type refusal ::
          {:git_credential_bot_token_refused,
           {:scopes, [String.t()]}
           | {:membership, [String.t()]}
           | {:resources, [String.t()]}
           | {:granular_permissions, [String.t()]}
           | {:granular_boundary, [String.t()]}
           | {:rejected, 401 | 403}
           | :not_reachable
           | :no_expiry
           | :expired
           | :inactive
           | :not_a_member}
          | {:git_credential_bot_token_unverifiable, String.t()}

  @doc "The scopes a bot token may carry."
  @spec allowed_scopes() :: [String.t()]
  def allowed_scopes, do: @allowed_scopes

  @doc "The permissions a fine-grained bot token may carry (unverified names; see the moduledoc)."
  @spec allowed_granular_permissions() :: [String.t()]
  def allowed_granular_permissions, do: @allowed_granular_permissions

  @doc "Days ahead of the expiry `arb doctor` starts to warn."
  @spec warn_days() :: pos_integer()
  def warn_days, do: @warn_days

  @doc """
  Checks `token` for the parsed `entry` pinned to `remote`; `siblings` is the raw
  `git_credentials.repos` map (the other entries that widen the allowed projects).
  `req_options` are merged into each request.
  """
  @spec check(map(), String.t(), String.t(), map(), keyword()) :: :ok | {:error, refusal()}
  def check(entry, token, remote, repos, req_options) do
    allowed = allowed_projects(entry, remote, repos)

    with :ok <- check_configured_expiry(entry.expires_at) do
      verified({:full, remote, Enum.sort(allowed)}, entry, token, fn ->
        with {:ok, pat} <- self_pat(entry, token, req_options),
             :ok <- check_pat(pat),
             {:ok, reach} <- reach(entry, token, pat, req_options) do
          check_reach(reach, allowed, remote)
        end
      end)
    end
  end

  @doc """
  The token-only half of `check/5`: scopes, expiry and that GitLab answers
  `personal_access_tokens/self`, with no project pinned. For an entry whose `remote`
  is only known at spawn.
  """
  @spec check_token(map(), String.t(), keyword()) :: :ok | {:error, refusal()}
  def check_token(entry, token, req_options) do
    with :ok <- check_configured_expiry(entry.expires_at) do
      verified(:token, entry, token, fn ->
        with {:ok, pat} <- self_pat(entry, token, req_options), do: check_pat(pat)
      end)
    end
  end

  @default_backoff_ms [5_000, 15_000]
  # Short on purpose: a revoked or narrowed token is caught within this long.
  @default_cache_ttl_ms :timer.minutes(5)

  @doc """
  The verification retry/cache policy (`config :arbiter, :gitlab_bot_verify`):
  `:backoff_ms` is the wait before each retry of an *unverifiable* answer (timeout,
  transport error, 5xx, 429), so `length + 1` attempts in all (default `#{inspect(@default_backoff_ms)}`,
  about 20s of waiting); `:cache_ttl_ms` is how long a *passing* verification is reused
  (default #{div(@default_cache_ttl_ms, 60_000)} minutes; `0` disables the cache).
  """
  @spec verify_policy() :: %{backoff_ms: [non_neg_integer()], cache_ttl_ms: non_neg_integer()}
  def verify_policy do
    config = Application.get_env(:arbiter, :gitlab_bot_verify, [])

    %{
      backoff_ms: Keyword.get(config, :backoff_ms, @default_backoff_ms),
      cache_ttl_ms: Keyword.get(config, :cache_ttl_ms, @default_cache_ttl_ms)
    }
  end

  @cache_table {__MODULE__, :verified}

  @doc "Forgets every cached passing verification."
  @spec clear_cache() :: :ok
  def clear_cache do
    :persistent_term.erase(@cache_table)
    :ok
  end

  # Only `:ok` is cached (keyed on a hash of the token, so a rotated token is checked
  # afresh); a refusal or an unverifiable answer never is. An unverifiable answer is
  # retried with the policy's backoff before it is returned; a refusal (including a
  # 401/403 rejection) is returned at once.
  defp verified(scope, entry, token, fun) do
    %{backoff_ms: backoff, cache_ttl_ms: ttl} = verify_policy()
    key = {:crypto.hash(:sha256, token), api(entry), scope}
    now = System.monotonic_time(:millisecond)

    if ttl > 0 and cached?(key, now) do
      :ok
    else
      with :ok <- attempt(fun, backoff) do
        if ttl > 0, do: remember(key, now + ttl, now)
        :ok
      end
    end
  end

  defp attempt(fun, backoff) do
    case fun.() do
      {:error, {:git_credential_bot_token_unverifiable, _}} = error ->
        case backoff do
          [wait | rest] ->
            Process.sleep(wait)
            attempt(fun, rest)

          [] ->
            error
        end

      other ->
        other
    end
  end

  defp cached?(key, now) do
    case Map.get(:persistent_term.get(@cache_table, %{}), key) do
      expires when is_integer(expires) -> expires > now
      _ -> false
    end
  end

  defp remember(key, expires, now) do
    live = for {k, e} <- :persistent_term.get(@cache_table, %{}), e > now, into: %{}, do: {k, e}
    :persistent_term.put(@cache_table, Map.put(live, key, expires))
  end

  # The operator's own record of the expiry: a date in the past is enough to refuse,
  # without a round trip.
  defp check_configured_expiry(nil), do: :ok

  defp check_configured_expiry(expires_at) do
    case parse_date(expires_at) do
      %Date{} = date ->
        if Date.compare(date, Date.utc_today()) == :lt,
          do: refused(:expired),
          else: :ok

      nil ->
        :ok
    end
  end

  defp check_pat(%{} = pat) do
    cond do
      Map.get(pat, "active") == false or Map.get(pat, "revoked") == true ->
        refused(:inactive)

      Map.has_key?(pat, "granular_scopes") ->
        with :ok <- check_granular_permissions(Map.get(pat, "granular_scopes")),
             do: check_pat_expiry(pat)

      true ->
        extra = pat |> Map.get("scopes") |> List.wrap() |> Enum.reject(&(&1 in @allowed_scopes))

        if extra == [],
          do: check_pat_expiry(pat),
          else: refused({:scopes, Enum.sort(extra)})
    end
  end

  defp check_pat_expiry(pat) do
    case parse_date(Map.get(pat, "expires_at")) do
      nil ->
        refused(:no_expiry)

      %Date{} = date ->
        if Date.compare(date, Date.utc_today()) == :lt, do: refused(:expired), else: :ok
    end
  end

  # A fine-grained token: the permissions across every resource entry. An unreadable
  # list is unverifiable, never "no extras".
  defp check_granular_permissions([_ | _] = scopes) do
    if Enum.all?(scopes, &(is_map(&1) and is_list(Map.get(&1, "permissions")))) do
      extra =
        scopes
        |> Enum.flat_map(&Map.fetch!(&1, "permissions"))
        |> Enum.map(&to_string/1)
        |> Enum.reject(&(&1 in @allowed_granular_permissions))
        |> Enum.uniq()

      if extra == [], do: :ok, else: refused({:granular_permissions, Enum.sort(extra)})
    else
      unverifiable("granular_scopes: an entry without a permissions list")
    end
  end

  defp check_granular_permissions(_),
    do: unverifiable("granular_scopes: no resources listed, so the token's reach is unknown")

  # What the token reaches: `{:membership, paths}` for a classic PAT (the bot's
  # memberships), `{:resources, paths}` for a fine-grained one (its own resource list).
  @spec reach(map(), String.t(), map(), keyword()) ::
          {:ok, {:membership | :resources, [String.t()]}} | {:error, refusal()}
  defp reach(entry, token, pat, req_options) do
    if Map.has_key?(pat, "granular_scopes") do
      with {:ok, paths} <- granular_projects(entry, token, pat, req_options),
           do: {:ok, {:resources, paths}}
    else
      with {:ok, paths} <- memberships(entry, token, req_options),
           do: {:ok, {:membership, paths}}
    end
  end

  # Each resource entry must name exactly one project; the ids are then resolved to
  # paths. Callers have already run `check_granular_permissions/1`, so `scopes` is a
  # non-empty list of maps.
  defp granular_projects(entry, token, pat, req_options) do
    scopes = Map.fetch!(pat, "granular_scopes")

    wide =
      for scope <- scopes, not project_scope?(scope), do: describe_boundary(scope)

    if wide == [] do
      ids = scopes |> Enum.map(&Map.fetch!(&1, "project_id")) |> Enum.uniq()

      with {:ok, by_id} <- associations(entry, token, req_options) do
        case Enum.reject(ids, &Map.has_key?(by_id, &1)) do
          [] ->
            {:ok, Enum.map(ids, &Map.fetch!(by_id, &1))}

          missing ->
            unverifiable(
              "project id(s) #{Enum.join(missing, ", ")} are not in the token's associations"
            )
        end
      end
    else
      refused({:granular_boundary, wide |> Enum.uniq() |> Enum.sort()})
    end
  end

  defp project_scope?(scope),
    do: scope["access"] == "selected_memberships" and is_integer(scope["project_id"])

  defp describe_boundary(%{"access" => "selected_memberships", "group_id" => id})
       when is_integer(id),
       do: "group #{id} (every project in it)"

  defp describe_boundary(%{"access" => access}) when is_binary(access), do: "access #{access}"
  defp describe_boundary(_), do: "an unrecognised resource entry"

  defp check_reach({kind, reached}, allowed, remote) do
    allowed = MapSet.new(Enum.map(allowed, &String.downcase/1))
    reached_map = Map.new(reached, &{String.downcase(&1), &1})

    extra =
      reached_map
      |> Enum.reject(fn {key, _} -> MapSet.member?(allowed, key) end)
      |> Enum.map(&elem(&1, 1))

    cond do
      extra != [] -> refused({kind, Enum.sort(extra)})
      not Map.has_key?(reached_map, String.downcase(remote)) -> refused(not_reached(kind))
      true -> :ok
    end
  end

  defp not_reached(:membership), do: :not_a_member
  defp not_reached(:resources), do: :not_reachable

  defp refused(reason), do: {:error, {:git_credential_bot_token_refused, reason}}

  @doc """
  The projects (`owner/repo` paths) the bot may reach: `remote`, the entry's
  `projects`, and the `remote` / `projects` of every `gitlab_bot_token` entry in
  `repos` with the same secret and host.
  """
  @spec allowed_projects(map(), String.t(), map()) :: [String.t()]
  def allowed_projects(entry, remote, repos) do
    siblings =
      for {_repo, %{} = other} <- repos,
          other["kind"] == "gitlab_bot_token",
          other["secret"] == entry.secret,
          (other["host"] || "gitlab.com") == entry.host,
          path <- [other["remote"] | List.wrap(other["projects"])],
          is_binary(path),
          do: path

    Enum.uniq([remote | List.wrap(entry.projects)] ++ siblings)
  end

  # ---- GitLab API ------------------------------------------------------------------

  defp self_pat(entry, token, req_options) do
    case get(entry, token, "/personal_access_tokens/self", [], req_options) do
      {:ok, %Req.Response{status: 200, body: %{} = pat}} ->
        {:ok, pat}

      # A real rejection of the token: never retried, never cached, never softened.
      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        refused({:rejected, status})

      {:ok, %Req.Response{status: status}} ->
        unverifiable("personal_access_tokens/self: HTTP #{status}")

      {:error, why} ->
        unverifiable(why)
    end
  end

  defp memberships(entry, token, req_options), do: memberships(entry, token, req_options, 1, [])

  defp memberships(_entry, _token, _req_options, page, _acc) when page > @max_pages,
    do: unverifiable("more than #{@max_pages * @per_page} projects")

  defp memberships(entry, token, req_options, page, acc) do
    params = [membership: true, simple: true, per_page: @per_page, page: page]

    case get(entry, token, "/projects", params, req_options) do
      {:ok, %Req.Response{status: 200, body: body} = response} when is_list(body) ->
        acc = acc ++ for %{"path_with_namespace" => path} <- body, is_binary(path), do: path

        case Req.Response.get_header(response, "x-next-page") do
          [next | _] when next != "" -> memberships(entry, token, req_options, page + 1, acc)
          _ -> {:ok, acc}
        end

      {:ok, %Req.Response{status: status}} ->
        unverifiable("projects?membership=true: HTTP #{status}")

      {:error, why} ->
        unverifiable(why)
    end
  end

  # `GET /personal_access_tokens/self/associations` -> `%{project id => path}`.
  defp associations(entry, token, req_options),
    do: associations(entry, token, req_options, 1, %{})

  defp associations(_entry, _token, _req_options, page, _acc) when page > @max_pages,
    do: unverifiable("more than #{@max_pages * @per_page} associations")

  defp associations(entry, token, req_options, page, acc) do
    params = [per_page: @per_page, page: page]
    path = "/personal_access_tokens/self/associations"

    case get(entry, token, path, params, req_options) do
      {:ok, %Req.Response{status: 200, body: %{"projects" => projects}} = response}
      when is_list(projects) ->
        acc =
          for %{"id" => id, "path_with_namespace" => p} <- projects,
              is_integer(id),
              is_binary(p),
              into: acc,
              do: {id, p}

        case Req.Response.get_header(response, "x-next-page") do
          [next | _] when next != "" -> associations(entry, token, req_options, page + 1, acc)
          _ -> {:ok, acc}
        end

      {:ok, %Req.Response{status: 200}} ->
        unverifiable("personal_access_tokens/self/associations: unreadable answer")

      {:ok, %Req.Response{status: status}} ->
        unverifiable("personal_access_tokens/self/associations: HTTP #{status}")

      {:error, why} ->
        unverifiable(why)
    end
  end

  defp get(entry, token, path, params, req_options) do
    request =
      Keyword.merge(
        [
          url: api(entry) <> path,
          params: params,
          headers: [{"private-token", token}],
          retry: false,
          receive_timeout: 15_000
        ],
        req_options
      )

    case Req.get(request) do
      {:ok, _} = ok -> ok
      {:error, exception} -> {:error, scrub(Exception.message(exception), token)}
    end
  end

  defp unverifiable(why), do: {:error, {:git_credential_bot_token_unverifiable, why}}

  defp scrub(message, token), do: String.replace(message, token, "[redacted]")

  # `api_url` is the REST base (`https://gitlab.example.com/api/v4`); the default follows `host`.
  defp api(%{api_url: url}) when is_binary(url) and url != "", do: String.trim_trailing(url, "/")
  defp api(%{host: host}), do: "https://#{host}/api/v4"

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(String.slice(value, 0, 10)) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  # ---- expiry report (doctor) --------------------------------------------------------

  @type expiry :: %{
          repo: String.t(),
          secret: String.t(),
          host: String.t(),
          expires_at: Date.t() | nil,
          days_left: integer() | nil,
          source: :live | :config | :unknown
        }

  @doc """
  One row per distinct bot token (secret + host) in the workspace's
  `git_credentials`, with its expiry: asked of GitLab (`source: :live`) unless
  `probe: false`, else — or when GitLab cannot be reached — the entry's
  `expires_at` (`:config`), else `:unknown`. Options: `:probe` (default `true`),
  `:req_options`.
  """
  @spec expiries(map() | nil, keyword()) :: [expiry()]
  def expiries(workspace, opts \\ []) do
    probe? = Keyword.get(opts, :probe, true)
    req_options = Keyword.get(opts, :req_options, [])
    store = secret_store(workspace)

    workspace
    |> Arbiter.Worker.GitCredential.block()
    |> Map.get("repos", %{})
    |> Enum.filter(fn {_repo, entry} -> match?(%{"kind" => "gitlab_bot_token"}, entry) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.uniq_by(fn {_repo, e} -> {e["secret"], e["host"] || "gitlab.com"} end)
    |> Enum.map(fn {repo, entry} ->
      expiry_row(to_string(repo), entry, store, probe?, req_options)
    end)
  end

  defp expiry_row(repo, entry, store, probe?, req_options) do
    parsed = %{
      host: entry["host"] || "gitlab.com",
      api_url: entry["api_url"]
    }

    live = if probe?, do: live_expiry(parsed, Map.get(store, entry["secret"]), req_options)
    configured = parse_date(entry["expires_at"])

    {date, source} =
      cond do
        match?(%Date{}, live) -> {live, :live}
        configured -> {configured, :config}
        true -> {nil, :unknown}
      end

    %{
      repo: repo,
      secret: entry["secret"],
      host: parsed.host,
      expires_at: date,
      days_left: date && Date.diff(date, Date.utc_today()),
      source: source
    }
  end

  defp live_expiry(_parsed, token, _req_options) when not is_binary(token) or token == "", do: nil

  defp live_expiry(parsed, token, req_options) do
    case self_pat(parsed, token, req_options) do
      {:ok, pat} -> parse_date(Map.get(pat, "expires_at"))
      _ -> nil
    end
  end

  @type unreachable :: %{
          repo: String.t(),
          remote: String.t(),
          secret: String.t(),
          host: String.t()
        }

  @doc """
  The configured repos whose project the token cannot reach (bd-8h80lm), one row
  per repo: each `gitlab_bot_token` entry with a `remote` is checked against what
  its token reaches (the bot's memberships for a classic PAT, the token's own
  resources for a fine-grained one). A token whose reach cannot be read (GitLab
  unreachable, an unreadable answer, a group-wide boundary) yields no rows: the
  dispatch guard, not the report, is what refuses it. Options as `expiries/2`;
  with `probe: false` nothing is asked and no rows come back.
  """
  @spec unreachable(map() | nil, keyword()) :: [unreachable()]
  def unreachable(workspace, opts \\ []) do
    if Keyword.get(opts, :probe, true) do
      req_options = Keyword.get(opts, :req_options, [])
      store = secret_store(workspace)

      workspace
      |> Arbiter.Worker.GitCredential.block()
      |> Map.get("repos", %{})
      |> Enum.filter(fn {_repo, entry} ->
        match?(%{"kind" => "gitlab_bot_token", "remote" => r} when is_binary(r), entry)
      end)
      |> Enum.group_by(fn {_repo, e} ->
        {e["secret"], e["host"] || "gitlab.com", e["api_url"]}
      end)
      |> Enum.flat_map(&unreachable_in_group(&1, store, req_options))
      |> Enum.sort_by(& &1.repo)
    else
      []
    end
  end

  # One token (secret + host + api_url) and the entries that use it.
  defp unreachable_in_group({{secret, host, api_url}, group}, store, req_options) do
    case reached_paths(%{host: host, api_url: api_url}, Map.get(store, secret), req_options) do
      {:ok, paths} ->
        reached = MapSet.new(paths, &String.downcase/1)

        for {repo, e} <- group, not MapSet.member?(reached, String.downcase(e["remote"])) do
          %{repo: to_string(repo), remote: e["remote"], secret: secret, host: host}
        end

      :unknown ->
        []
    end
  end

  defp reached_paths(_parsed, token, _req_options) when not is_binary(token) or token == "",
    do: :unknown

  defp reached_paths(parsed, token, req_options) do
    with {:ok, pat} <- self_pat(parsed, token, req_options),
         {:ok, {_kind, paths}} <- reach(parsed, token, pat, req_options) do
      {:ok, paths}
    else
      _ -> :unknown
    end
  end

  defp secret_store(%Workspace{} = ws),
    do: Map.merge(Workspace.worker_env_map(ws), Workspace.secrets_map(ws))

  defp secret_store(_), do: %{}
end
