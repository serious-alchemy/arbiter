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

  Both checks fail closed: an answer that cannot be read is a refusal, never a
  delivery. Nothing here logs or returns the token.
  """

  alias Arbiter.Tasks.Workspace

  @allowed_scopes ~w(read_api read_repository write_repository)
  @per_page 100
  @max_pages 20
  @warn_days 14

  @type refusal ::
          {:git_credential_bot_token_refused,
           {:scopes, [String.t()]}
           | {:membership, [String.t()]}
           | :no_expiry
           | :expired
           | :inactive
           | :not_a_member}
          | {:git_credential_bot_token_unverifiable, String.t()}

  @doc "The scopes a bot token may carry."
  @spec allowed_scopes() :: [String.t()]
  def allowed_scopes, do: @allowed_scopes

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
    with :ok <- check_configured_expiry(entry.expires_at),
         {:ok, pat} <- self_pat(entry, token, req_options),
         :ok <- check_pat(pat),
         {:ok, member_of} <- memberships(entry, token, req_options) do
      check_membership(member_of, allowed_projects(entry, remote, repos), remote)
    end
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
    scopes = List.wrap(Map.get(pat, "scopes"))
    extra = Enum.reject(scopes, &(&1 in @allowed_scopes))

    cond do
      Map.get(pat, "active") == false or Map.get(pat, "revoked") == true ->
        refused(:inactive)

      extra != [] ->
        refused({:scopes, Enum.sort(extra)})

      true ->
        case parse_date(Map.get(pat, "expires_at")) do
          nil ->
            refused(:no_expiry)

          %Date{} = date ->
            if Date.compare(date, Date.utc_today()) == :lt, do: refused(:expired), else: :ok
        end
    end
  end

  defp check_membership(member_of, allowed, remote) do
    allowed = MapSet.new(Enum.map(allowed, &String.downcase/1))
    member = Map.new(member_of, &{String.downcase(&1), &1})

    extra =
      member
      |> Enum.reject(fn {key, _} -> MapSet.member?(allowed, key) end)
      |> Enum.map(&elem(&1, 1))

    cond do
      extra != [] -> refused({:membership, Enum.sort(extra)})
      not Map.has_key?(member, String.downcase(remote)) -> refused(:not_a_member)
      true -> :ok
    end
  end

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

  defp secret_store(%Workspace{} = ws),
    do: Map.merge(Workspace.worker_env_map(ws), Workspace.secrets_map(ws))

  defp secret_store(_), do: %{}
end
