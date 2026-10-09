defmodule Arbiter.Worker.GitCredential do
  @moduledoc """
  Scoped git and tracker credentials (G16, bd-9cygoo;
  `docs/design/guardrail-profiles.md` §5.5, §9): a worker pushes with a
  credential that reaches **one repo**, never the operator's ssh-agent or keys,
  and the tracker token it is given is scoped the same way. No worker is given a
  token with the `gist` or `delete_repo` scope.

  Setup is per repo, in the workspace config (see `docs/git-credentials.md`):

      "git_credentials": {
        "legacy_operator": false,
        "repos": {
          "tonic":  {"kind": "deploy_key", "key_secret": "TONIC_DEPLOY_KEY"},
          "vstim":  {"kind": "github_app", "app_id": "123", "installation_id": "456",
                     "private_key_secret": "ARBITER_APP_KEY"},
          "infra":  {"kind": "token", "token_secret": "INFRA_TOKEN", "host": "gitlab.com",
                     "username": "oauth2"},
          "scratch": {"legacy_operator": true}
        }
      }

  The secret names are keys of the workspace's encrypted `secrets` store.

    * `deploy_key` — an SSH private key registered as a deploy key on that one
      repo (GitHub and GitLab both bind a deploy key to a single repo).
    * `github_app` — a GitHub App installed on the repo. At each dispatch
      Arbiter mints an installation token restricted (`repositories`) to that
      repo with only the permissions a worker needs.
    * `token` — a fine-grained / project access token for one repo (GitHub or
      GitLab). A classic GitHub PAT is refused: it cannot be limited to a repo.

  ## When it is required

  `plan/3` decides, per spawn. A spawn that needs push (an implementer; a
  reviewer does not, and neither does a spawn the host pushes for) is **refused**
  when no scoped credential is configured for its repo, unless the workspace (or
  that repo) sets `legacy_operator: true`. This is enforced on a *guarded*
  install (guardrail subject rules exist, `Arbiter.Guardrails.guarded?/0`) and on
  any workspace that has a `git_credentials` block; an install with neither
  behaves exactly as before (`mode: :unenforced`), so upgrading does not
  silently stop every dispatch.

  ## Delivery

    * **Deploy key** — written `0600` into a per-worker directory
      (`stage/3`) and named by `GIT_SSH_COMMAND` (`-i <key> -o IdentitiesOnly=yes
      -o IdentityAgent=none`), so neither the operator's agent nor their default
      keys are offered. The agy jail binds nothing else and blanks the default
      identities (`Arbiter.Worker.Jail`'s `:git_ssh_key`); podman gets it as a
      `--secret` (`podman_secrets/2`).
    * **Token** — in the worker's env (`ARB_GIT_TOKEN`; a podman `--secret` of
      type env) and served by a git credential helper that answers **only for
      the repo's own path** (`credential.useHttpPath`): a push to another repo
      finds no credential and fails, whatever the token could reach.
    * **Tracker** — `GH_TOKEN` for a `tracker_write` projection is the repo-scoped
      token (a second, narrower App installation token, or the `token` kind's
      own), not a binding's broad one.
    * An ssh agent socket is never delivered (`SSH_AUTH_SOCK` stays unset).
  """

  alias Arbiter.Guardrails.Config, as: GuardrailsConfig
  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.GitCredential.Material

  require Logger

  @kinds ~w(deploy_key token github_app)
  @remote_re ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.\/-]+\z/
  @host_re ~r/\A[A-Za-z0-9.-]+\z/
  @name_re ~r/\A[A-Za-z0-9_.:-]+\z/

  @entry_keys ~w(kind key_secret token_secret private_key_secret app_id installation_id host
                 username remote api_url legacy_operator)
  @block_keys ~w(legacy_operator repos)

  defstruct mode: :unenforced, repo: nil, entry: nil

  @type kind :: :deploy_key | :token | :github_app
  @type entry :: %{
          required(:kind) => kind(),
          optional(atom()) => term()
        }
  @type t :: %__MODULE__{
          mode: :scoped | :legacy | :unenforced | :not_needed,
          repo: String.t() | nil,
          entry: entry() | nil
        }

  # ---- config -----------------------------------------------------------------

  @doc "The workspace's `git_credentials` block (string keys), or `%{}`."
  @spec block(map() | nil) :: map()
  def block(%{config: %{} = config}), do: block_of(config)
  def block(%{"config" => %{} = config}), do: block_of(config)
  def block(_), do: %{}

  defp block_of(config) do
    case Map.get(config, "git_credentials") || Map.get(config, :git_credentials) do
      %{} = block -> GuardrailsConfig.stringify(block)
      _ -> %{}
    end
  end

  @doc "True when the workspace config carries a non-empty `git_credentials` block."
  @spec configured?(map() | nil) :: boolean()
  def configured?(workspace), do: block(workspace) != %{}

  @doc """
  Whether a scoped credential is *required* for a spawn: the install is guarded,
  or the workspace has a `git_credentials` block.
  """
  @spec enforced?(map() | nil, boolean()) :: boolean()
  def enforced?(workspace, guarded?), do: guarded? or configured?(workspace)

  @doc """
  The credential decision for a spawn of `repo` in `workspace`.

  Options: `:role` (`:implementer`, the default, or `:reviewer`), `:guarded?`
  (the spawn's projection is guarded), `:host_pushes?` (the host pushes the
  branch, so the worker needs no credential).

  `{:error, {:git_credential_missing, repo, message}}` is the refusal.
  """
  @spec plan(map() | nil, String.t() | nil, keyword()) ::
          {:ok, t()} | {:error, {:git_credential_missing, String.t() | nil, String.t()}}
  def plan(workspace, repo, opts \\ []) do
    role = Keyword.get(opts, :role, :implementer)
    block = block(workspace)
    entry = repo_entry(block, repo)

    cond do
      role == :reviewer or Keyword.get(opts, :host_pushes?, false) ->
        {:ok, %__MODULE__{mode: :not_needed, repo: repo}}

      scoped?(entry) ->
        {:ok, %__MODULE__{mode: :scoped, repo: repo, entry: parse_entry(entry)}}

      legacy?(block, entry) ->
        {:ok, %__MODULE__{mode: :legacy, repo: repo}}

      enforced?(workspace, Keyword.get(opts, :guarded?, false)) ->
        {:error, {:git_credential_missing, repo, missing_message(repo)}}

      true ->
        {:ok, %__MODULE__{mode: :unenforced, repo: repo}}
    end
  end

  defp repo_entry(block, repo) when is_binary(repo) and repo != "" do
    case block do
      %{"repos" => %{} = repos} ->
        case RepoConfig.find_entry(repos, repo) do
          %{} = entry -> entry
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp repo_entry(_block, _repo), do: nil

  defp scoped?(%{"kind" => kind}) when kind in @kinds, do: true
  defp scoped?(_), do: false

  # A repo entry's own `legacy_operator` (true or false) wins over the workspace's.
  defp legacy?(_block, %{"legacy_operator" => value}) when is_boolean(value), do: value
  defp legacy?(block, _entry), do: Map.get(block, "legacy_operator") == true

  defp missing_message(repo) do
    name = repo || "(no repo)"

    "no scoped git credential is configured for repo #{name}, and a worker that pushes " <>
      "must not run on the operator's ssh-agent or keys. Register a per-repo deploy key, " <>
      "GitHub App or repo-scoped token under the workspace's config git_credentials.repos." <>
      "#{name} (docs/git-credentials.md), or opt in to the operator's credential with " <>
      "git_credentials.legacy_operator: true"
  end

  defp parse_entry(entry) do
    %{
      kind: String.to_existing_atom(entry["kind"]),
      key_secret: entry["key_secret"],
      token_secret: entry["token_secret"],
      private_key_secret: entry["private_key_secret"],
      app_id: stringify_id(entry["app_id"]),
      installation_id: stringify_id(entry["installation_id"]),
      host: entry["host"] || "github.com",
      username: entry["username"] || "x-access-token",
      remote: entry["remote"],
      api_url: entry["api_url"]
    }
  end

  defp stringify_id(nil), do: nil
  defp stringify_id(id), do: to_string(id)

  # ---- validation ---------------------------------------------------------------

  @doc "Validate a workspace `git_credentials` block (shape only; secrets are checked at dispatch)."
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(%{} = block) do
    block = GuardrailsConfig.stringify(block)

    with :ok <- unknown_keys(block, @block_keys, "git_credentials"),
         :ok <- boolean(block, "legacy_operator", "git_credentials"),
         :ok <- validate_repos(Map.get(block, "repos")) do
      :ok
    end
  end

  def validate(_), do: {:error, "git_credentials must be a map"}

  defp validate_repos(nil), do: :ok

  defp validate_repos(%{} = repos) do
    Enum.reduce_while(repos, :ok, fn {repo, entry}, :ok ->
      case validate_entry(to_string(repo), entry) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_repos(_), do: {:error, "git_credentials.repos must be a map"}

  defp validate_entry(repo, %{} = entry) do
    entry = GuardrailsConfig.stringify(entry)
    where = "git_credentials.repos.#{repo}"

    with :ok <- unknown_keys(entry, @entry_keys, where),
         :ok <- boolean(entry, "legacy_operator", where),
         :ok <- validate_kind(entry, where),
         :ok <- optional_match(entry, "host", @host_re, where),
         :ok <- optional_match(entry, "remote", @remote_re, where),
         :ok <- optional_match(entry, "username", @name_re, where) do
      :ok
    end
  end

  defp validate_entry(repo, _), do: {:error, "git_credentials.repos.#{repo} must be a map"}

  defp validate_kind(entry, where) do
    case Map.get(entry, "kind") do
      nil ->
        if map_size(Map.delete(entry, "legacy_operator")) == 0,
          do: :ok,
          else: {:error, "#{where}.kind is required (#{Enum.join(@kinds, ", ")})"}

      "deploy_key" ->
        require_names(entry, ["key_secret"], where)

      "token" ->
        require_names(entry, ["token_secret"], where)

      "github_app" ->
        require_names(entry, ["app_id", "installation_id", "private_key_secret"], where)

      other ->
        {:error, "#{where}.kind #{inspect(other)} must be one of #{Enum.join(@kinds, ", ")}"}
    end
  end

  defp require_names(entry, keys, where) do
    case Enum.find(keys, fn key -> blank?(Map.get(entry, key)) end) do
      nil -> :ok
      key -> {:error, "#{where}.#{key} is required for kind #{entry["kind"]}"}
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp unknown_keys(map, allowed, where) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      unknown -> {:error, "#{where} has unknown key(s): #{Enum.join(Enum.sort(unknown), ", ")}"}
    end
  end

  defp boolean(map, key, where) do
    case Map.get(map, key) do
      nil -> :ok
      value when is_boolean(value) -> :ok
      _ -> {:error, "#{where}.#{key} must be a boolean"}
    end
  end

  defp optional_match(map, key, re, where) do
    case Map.get(map, key) do
      nil -> :ok
      value when is_binary(value) -> if value =~ re, do: :ok, else: bad(where, key)
      _ -> bad(where, key)
    end
  end

  defp bad(where, key), do: {:error, "#{where}.#{key} is not valid"}

  # ---- remotes ------------------------------------------------------------------

  @doc """
  The `owner/repo` path of a git remote URL (`git@host:o/r.git`,
  `https://host/o/r`, `ssh://git@host/o/r.git`), or `:error`.
  """
  @spec parse_remote(String.t()) :: {:ok, String.t()} | :error
  def parse_remote(url) when is_binary(url) do
    path =
      cond do
        match?(%URI{scheme: scheme} when scheme in ["http", "https", "ssh", "git"], URI.parse(url)) ->
          URI.parse(url).path

        match?([_, _], Regex.run(~r/\A[^\/@]+@[^:\/]+:(.+)\z/, url)) ->
          [_, path] = Regex.run(~r/\A[^\/@]+@[^:\/]+:(.+)\z/, url)
          path

        true ->
          nil
      end

    with path when is_binary(path) <- path,
         path = path |> String.trim("/") |> String.replace_suffix(".git", ""),
         true <- path =~ @remote_re do
      {:ok, path}
    else
      _ -> :error
    end
  end

  def parse_remote(_), do: :error

  # ---- materializing ---------------------------------------------------------------

  @push_permissions %{"contents" => "write", "metadata" => "read", "pull_requests" => "read"}
  @tracker_permissions %{
    "contents" => "read",
    "issues" => "write",
    "metadata" => "read",
    "pull_requests" => "write"
  }
  # Scopes that no worker may ever hold. A classic PAT cannot be limited to a
  # repo at all, so any OAuth-scoped token is refused; these are the ones that do
  # the most damage if one is ever allowed through.
  @forbidden_scopes ~w(gist delete_repo)

  @doc """
  Resolve a `:scoped` plan to its secrets (`{:ok, nil}` for any other mode).

  Options: `:remote` (the `owner/repo` the spawn's origin points at; the
  entry's own `remote` wins), `:tracker?` (also produce `tracker_token`),
  `:req_options` (merged into the forge requests; tests stub with `plug:`).

  A secret that is not in the workspace's store, a token that cannot be pinned
  to one repo, or a mint that fails is an error: the spawn is refused, never
  run on the operator's credential.
  """
  @spec materialize(t(), map() | nil, keyword()) :: {:ok, Material.t() | nil} | {:error, term()}
  def materialize(%__MODULE__{mode: :scoped, entry: entry}, workspace, opts) do
    case entry.kind do
      :deploy_key -> materialize_key(entry, workspace)
      :token -> materialize_token(entry, workspace, opts)
      :github_app -> materialize_app(entry, workspace, opts)
    end
  end

  def materialize(%__MODULE__{}, _workspace, _opts), do: {:ok, nil}

  defp materialize_key(entry, workspace) do
    with {:ok, key} <- secret(workspace, entry.key_secret) do
      {:ok, %Material{kind: :deploy_key, key: String.trim_trailing(key) <> "\n"}}
    end
  end

  defp materialize_token(entry, workspace, opts) do
    with {:ok, token} <- secret(workspace, entry.token_secret),
         {:ok, remote} <- remote(entry, opts),
         :ok <- check_token_scope(entry, token, opts) do
      {:ok,
       %Material{
         kind: :token,
         token: token,
         tracker_token: if(Keyword.get(opts, :tracker?, false), do: token),
         host: entry.host,
         username: entry.username,
         remote: remote
       }}
    end
  end

  defp materialize_app(entry, workspace, opts) do
    with {:ok, pem} <- secret(workspace, entry.private_key_secret),
         {:ok, remote} <- remote(entry, opts),
         repo = remote |> String.split("/") |> List.last(),
         {:ok, push} <- mint(entry, pem, repo, @push_permissions, opts),
         {:ok, tracker} <- maybe_mint_tracker(entry, pem, repo, opts) do
      {:ok,
       %Material{
         kind: :github_app,
         token: push,
         tracker_token: tracker,
         host: entry.host,
         username: "x-access-token",
         remote: remote
       }}
    end
  end

  defp maybe_mint_tracker(entry, pem, repo, opts) do
    if Keyword.get(opts, :tracker?, false),
      do: mint(entry, pem, repo, @tracker_permissions, opts),
      else: {:ok, nil}
  end

  defp secret(%Workspace{} = ws, name) when is_binary(name) do
    store = Map.merge(Workspace.worker_env_map(ws), Workspace.secrets_map(ws))

    case Map.get(store, name) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:git_credential_secret_missing, name}}
    end
  end

  defp secret(_workspace, name), do: {:error, {:git_credential_secret_missing, name}}

  # A token is pinned to the repo the spawn's origin names (or the entry's own
  # `remote`); without one the helper could not refuse another repo.
  defp remote(entry, opts) do
    case entry.remote || Keyword.get(opts, :remote) do
      remote when is_binary(remote) and remote != "" -> {:ok, remote}
      _ -> {:error, :git_credential_remote_unknown}
    end
  end

  @doc "The `owner/repo` of the `origin` remote of the checkout at `path`, or `nil`."
  @spec origin_remote(Path.t() | nil) :: String.t() | nil
  def origin_remote(path) when is_binary(path) do
    case System.cmd("git", ["-C", path, "config", "--get", "remote.origin.url"],
           stderr_to_stdout: true
         ) do
      {url, 0} ->
        case parse_remote(String.trim(url)) do
          {:ok, remote} -> remote
          :error -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def origin_remote(_), do: nil

  # ---- GitHub App ------------------------------------------------------------------

  defp mint(entry, pem, repo, permissions, opts) do
    with {:ok, jwt} <- app_jwt(entry.app_id, pem) do
      base = entry.api_url || "https://api.github.com"

      request =
        Keyword.merge(
          [
            url: "#{base}/app/installations/#{entry.installation_id}/access_tokens",
            json: %{"repositories" => [repo], "permissions" => permissions},
            headers: [
              {"authorization", "Bearer " <> jwt},
              {"accept", "application/vnd.github+json"},
              {"x-github-api-version", "2022-11-28"}
            ],
            retry: false,
            receive_timeout: 15_000
          ],
          Keyword.get(opts, :req_options, [])
        )

      case Req.post(request) do
        {:ok, %Req.Response{status: 201, body: %{"token" => token}}} when is_binary(token) ->
          {:ok, token}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:git_credential_mint_failed, status, message_of(body)}}

        {:error, exception} ->
          {:error, {:git_credential_mint_failed, :transport, Exception.message(exception)}}
      end
    end
  end

  defp message_of(%{"message" => message}) when is_binary(message), do: message
  defp message_of(_), do: "no message"

  defp app_jwt(app_id, pem) do
    now = System.system_time(:second)

    header = %{"alg" => "RS256", "typ" => "JWT"}
    claims = %{"iat" => now - 60, "exp" => now + 540, "iss" => app_id}
    signing_input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))

    with {:ok, key} <- private_key(pem) do
      signature = :public_key.sign(signing_input, :sha256, key)
      {:ok, signing_input <> "." <> b64(signature)}
    end
  end

  defp private_key(pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] -> {:ok, :public_key.pem_entry_decode(entry)}
      _ -> {:error, {:git_credential_bad_key, :not_pem}}
    end
  rescue
    _ -> {:error, {:git_credential_bad_key, :undecodable}}
  end

  defp b64(data), do: Base.url_encode64(data, padding: false)

  # ---- static-token scope check ---------------------------------------------------

  # A classic PAT answers `GET /user` with an `X-OAuth-Scopes` header; a
  # fine-grained token or an App installation token has none. Classic PATs reach
  # every repo their owner does (and may carry `gist` / `delete_repo`), so they
  # are refused. An unreachable API only warns.
  defp check_token_scope(%{host: "github.com"} = entry, token, opts) do
    request =
      Keyword.merge(
        [
          url: "#{entry.api_url || "https://api.github.com"}/user",
          headers: [
            {"authorization", "Bearer " <> token},
            {"accept", "application/vnd.github+json"}
          ],
          retry: false,
          receive_timeout: 10_000
        ],
        Keyword.get(opts, :req_options, [])
      )

    case Req.get(request) do
      {:ok, %Req.Response{} = response} ->
        case Req.Response.get_header(response, "x-oauth-scopes") do
          [] -> :ok
          [scopes | _] -> {:error, {:git_credential_token_too_broad, split_scopes(scopes)}}
        end

      {:error, exception} ->
        Logger.warning(
          "GitCredential: could not check the scopes of the #{entry.token_secret} token: " <>
            Exception.message(exception)
        )

        :ok
    end
  end

  defp check_token_scope(_entry, _token, _opts), do: :ok

  defp split_scopes(scopes), do: scopes |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  @doc "The scopes no worker credential may carry."
  @spec forbidden_scopes() :: [String.t()]
  def forbidden_scopes, do: @forbidden_scopes

  @doc "Human text for a `plan/3` or `materialize/3` refusal reason."
  @spec format_error(term()) :: String.t()
  def format_error({:git_credential_missing, _repo, message}), do: message

  def format_error({:git_credential_secret_missing, name}),
    do:
      "the scoped git credential names the workspace secret #{inspect(name)}, which is not set; " <>
        "refusing to fall back to the operator's credential"

  def format_error(:git_credential_remote_unknown),
    do:
      "cannot tell which repo the scoped git credential is for (no github/gitlab origin remote and " <>
        "no git_credentials.repos.<repo>.remote); refusing to issue an unpinned token"

  def format_error({:git_credential_mint_failed, status, message}),
    do: "minting the repo-scoped GitHub App token failed (#{status}): #{message}"

  def format_error({:git_credential_token_too_broad, scopes}),
    do:
      "the configured token is a classic personal access token (scopes: " <>
        "#{Enum.join(scopes, ", ")}) and cannot be limited to one repo; use a fine-grained " <>
        "token, a GitHub App or a deploy key"

  def format_error({:git_credential_bad_key, why}),
    do: "the GitHub App private key could not be read (#{why})"

  def format_error({:git_credential_stage_failed, reason}),
    do: "could not stage the scoped git credential: #{inspect(reason)}"

  def format_error(other), do: "scoped git credential unavailable: #{inspect(other)}"

  # ---- staging & delivery -----------------------------------------------------------

  @doc """
  The directory deploy keys are staged in, under the scratch root. Every jail blanks
  it (`Arbiter.Worker.Jail.mask_paths/0`) and binds back only its own key, so a
  sibling worker's key is unreadable; it has to exist by then, because a read-only
  bind of `/` shows a directory created after the jail started.
  """
  @spec default_dir() :: Path.t()
  def default_dir, do: Path.join(Arbiter.Config.Paths.scratch_root(), "git-key")

  @doc "Creates (`0700`) and returns `default_dir/0`."
  @spec ensure_default_dir() :: Path.t()
  def ensure_default_dir do
    dir = default_dir()
    _ = File.mkdir_p(dir)
    _ = File.chmod(dir, 0o700)
    dir
  end

  @doc """
  Writes the material's key (if it has one) for the worker `owner` and returns
  `%{dir:, key_path:, env:}`. The file is `0600` in a `0700` directory under the
  `default_dir/0` (`:root` overrides it); the directory is removed when `owner` exits. Idempotent per owner: a resume or a second
  caller (the agy jail, then the session) gets the same path.
  """
  @spec stage(Material.t() | nil, pid(), keyword()) ::
          {:ok, %{dir: Path.t() | nil, key_path: Path.t() | nil, env: [{String.t(), String.t()}]}}
          | {:error, term()}
  def stage(nil, _owner, _opts), do: {:ok, %{dir: nil, key_path: nil, env: []}}

  def stage(%Material{kind: :deploy_key, key: key} = material, owner, opts) do
    root = Keyword.get(opts, :root) || ensure_default_dir()
    hash = :crypto.hash(:sha256, :erlang.term_to_binary(owner))
    name = "git-key-" <> Base.encode32(binary_part(hash, 0, 8), case: :lower, padding: false)
    dir = Path.join(root, name)
    path = Path.join(dir, "key")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(path, key),
         :ok <- File.chmod(path, 0o600) do
      remove_when_down(owner, dir)
      {:ok, %{dir: dir, key_path: path, env: Material.env(material, path)}}
    else
      {:error, reason} -> {:error, {:git_credential_stage_failed, reason}}
    end
  end

  def stage(%Material{} = material, _owner, _opts),
    do: {:ok, %{dir: nil, key_path: nil, env: Material.env(material, nil)}}

  # A worker killed without cleaning up must not leave its key on disk: this
  # outlives nothing but the server (leftovers of a dead server go at the next
  # stage, `sweep/1`).
  defp remove_when_down(owner, dir) when is_pid(owner) do
    {:ok, _pid} =
      Task.start(fn ->
        ref = Process.monitor(owner)

        receive do
          {:DOWN, ^ref, :process, _, _} -> File.rm_rf(dir)
        end
      end)

    :ok
  end

  defp remove_when_down(_owner, _dir), do: :ok

  @doc """
  Removes staged keys older than `:max_age_ms` (default a day): what a server that
  died left behind. Run at boot.
  """
  @spec sweep(keyword()) :: [Path.t()]
  def sweep(opts \\ []) do
    root = Keyword.get(opts, :root) || default_dir()
    cutoff = System.os_time(:second) - div(Keyword.get(opts, :max_age_ms, 86_400_000), 1000)

    case File.ls(root) do
      {:ok, entries} ->
        stale =
          entries
          |> Enum.map(&Path.join(root, &1))
          |> Enum.filter(fn dir ->
            match?({:ok, %File.Stat{mtime: mtime}} when mtime < cutoff, File.stat(dir, time: :posix))
          end)

        Enum.each(stale, &File.rm_rf/1)
        stale

      _ ->
        []
    end
  end

  @key_options "-o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes"

  @doc "The ssh options that offer exactly the key at `key_path` and no agent."
  @spec ssh_options(Path.t()) :: String.t()
  def ssh_options(key_path), do: "-i #{shell_quote(key_path)} #{@key_options}"

  @doc """
  The `GIT_SSH_COMMAND` for a deploy key at `key_path` where no jail composes it
  (`-F /dev/null`: a `Host` block's `IdentityFile` cannot add the operator's key).
  """
  @spec ssh_command(Path.t()) :: String.t()
  def ssh_command(key_path), do: "ssh -F /dev/null " <> ssh_options(key_path)

  defp shell_quote(path) do
    if path =~ ~r/\A[A-Za-z0-9_\/.@:+=,-]+\z/,
      do: path,
      else: "'" <> String.replace(path, "'", "'\\''") <> "'"
  end

  @podman_key_name "arb_git_key"

  @doc "Where a deploy key's podman secret appears inside the container."
  @spec podman_key_path() :: String.t()
  def podman_key_path, do: "/run/secrets/" <> @podman_key_name

  @doc """
  The podman secrets that carry `material` into a container (`--secret`), named
  from `prefix` (the container name): a deploy key as a mounted file, a token as
  an env var. Value-bearing; create them with `podman secret create` and remove
  them with the container.
  """
  @spec podman_secrets(Material.t() | nil, String.t()) :: [map()]
  def podman_secrets(nil, _prefix), do: []

  def podman_secrets(%Material{kind: :deploy_key, key: key}, prefix),
    do: [%{name: prefix <> "-git-key", type: :mount, target: @podman_key_name, value: key}]

  def podman_secrets(%Material{token: token}, prefix) when is_binary(token),
    do: [%{name: prefix <> "-git-token", type: :env, target: "ARB_GIT_TOKEN", value: token}]

  def podman_secrets(%Material{}, _prefix), do: []

  @doc """
  The env a container carries for `material` alongside its `--secret`s: the
  token's value is *not* in it (it arrives as a secret), only the git config
  that makes use of it. A deploy key adds nothing here: its `GIT_SSH_COMMAND`
  (`ssh_command/1` of `podman_key_path/0`) is composed with the container's proxy
  `ProxyCommand` by `Arbiter.Worker.ContainerSpawn`.
  """
  @spec container_env(Material.t() | nil) :: [{String.t(), String.t()}]
  def container_env(nil), do: []

  def container_env(%Material{kind: :deploy_key}), do: []

  def container_env(%Material{} = material),
    do: material |> Material.env(nil) |> Enum.reject(fn {name, _} -> name == "ARB_GIT_TOKEN" end)

  # ---- the spawn seam -------------------------------------------------------------------

  @type prepared :: %{
          mode: atom(),
          material: Material.t() | nil,
          key_path: Path.t() | nil,
          env: [{String.t(), String.t()}],
          redact: [String.t()]
        }

  @doc """
  Everything a spawn needs of its credential: `material/3`'s secrets, a deploy
  key staged on the host (`stage/3`) unless the spawn is a container (`:container?`;
  its key is a `podman_secrets/2` secret), and the env that delivers them.

  Options: `:worktree_path` (whose `origin` pins a token), `:projection` (a
  `tracker_write` grant also asks for a tracker token), `:container?`, `:root`,
  `:req_options`, `:remote`.
  """
  @spec prepare(t() | nil, map() | nil, pid(), keyword()) :: {:ok, prepared()} | {:error, term()}
  def prepare(plan, workspace, owner, opts) do
    mode = if match?(%__MODULE__{}, plan), do: plan.mode, else: :unenforced
    tracker? = match?(%{claims: [_ | _], tracker_env: var} when is_binary(var), Keyword.get(opts, :projection))

    materialize_opts =
      [
        remote: Keyword.get(opts, :remote) || origin_remote(Keyword.get(opts, :worktree_path)),
        tracker?: tracker?
      ] ++ Keyword.take(opts, [:req_options])

    with {:ok, material} <- materialize(plan || %__MODULE__{}, workspace, materialize_opts),
         {:ok, staged} <- stage_unless_container(material, owner, opts) do
      {:ok,
       %{
         mode: mode,
         material: material,
         key_path: staged.key_path,
         env: staged.env,
         redact: redact_values(material)
       }}
    end
  end

  defp stage_unless_container(material, owner, opts) do
    if Keyword.get(opts, :container?, false),
      do: {:ok, %{dir: nil, key_path: nil, env: []}},
      else: stage(material, owner, Keyword.take(opts, [:root]))
  end

  @doc """
  The worker env pairs with the credential applied: the tracker var (the
  projection's `tracker_env`) carries the repo-scoped tracker token instead of
  whatever a binding named, and the delivery env is appended.

  Where the credential has no tracker token of its own (a deploy key), the
  binding's token stays, but under a scoped plan it is checked first
  (`verify_tracker_token/2`): a classic PAT reaches every repo its owner does and
  is refused. A legacy or unenforced spawn is left exactly as it was.
  """
  @spec spawn_env(prepared(), map(), [{String.t(), String.t()}], keyword()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def spawn_env(%{mode: mode} = git, projection, pairs, opts) when mode in [:scoped] do
    var = Map.get(projection, :tracker_env)

    with {:ok, pairs} <- scope_tracker(git, var, pairs, opts) do
      {:ok, pairs ++ git.env}
    end
  end

  def spawn_env(git, _projection, pairs, _opts), do: {:ok, pairs ++ Map.get(git, :env, [])}

  defp scope_tracker(_git, nil, pairs, _opts), do: {:ok, pairs}

  defp scope_tracker(git, var, pairs, opts) do
    case tracker_token(git.material) do
      token when is_binary(token) ->
        {:ok, List.keystore(Enum.reject(pairs, &(elem(&1, 0) == var)), var, 0, {var, token})}

      nil ->
        case List.keyfind(pairs, var, 0) do
          {^var, token} ->
            with :ok <- verify_tracker_token(token, opts), do: {:ok, pairs}

          nil ->
            {:ok, pairs}
        end
    end
  end

  @doc """
  Refuses a tracker token that is a classic GitHub PAT (`X-OAuth-Scopes` is
  reported): it cannot be limited to one repo and may carry `gist` or
  `delete_repo`. A fine-grained token or an App installation token passes.
  """
  @spec verify_tracker_token(String.t(), keyword()) :: :ok | {:error, term()}
  def verify_tracker_token(token, opts \\ []) when is_binary(token),
    do: check_token_scope(%{host: "github.com", api_url: nil, token_secret: "tracker_write binding"}, token, opts)

  # ---- tracker & redaction ------------------------------------------------------------

  @doc "The repo-scoped token for `tracker_write`, or `nil` (a deploy key has none)."
  @spec tracker_token(Material.t() | nil) :: String.t() | nil
  def tracker_token(%Material{tracker_token: token}) when is_binary(token), do: token
  def tracker_token(_), do: nil

  @doc "Secret strings the output scrubber must mask for `material`."
  @spec redact_values(Material.t() | nil) :: [String.t()]
  def redact_values(nil), do: []

  def redact_values(%Material{key: key, token: token, tracker_token: tracker}) do
    key_value = if is_binary(key), do: String.trim(key)
    Enum.filter([key_value, token, tracker], &(is_binary(&1) and &1 != ""))
  end
end
