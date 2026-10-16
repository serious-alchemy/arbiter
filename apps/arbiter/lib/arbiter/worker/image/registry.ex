defmodule Arbiter.Worker.Image.Registry do
  @moduledoc """
  The registry the image publisher pushes to (K8, bd-9vrbx7,
  `docs/design/remote-workers.md` §11; per repo since KH12, §20.10).

  `fetch/1` is the install-wide `nodes.registry` settings, `:unset` unless
  configured. `resolve/3` is what a repo's images use: the repo's
  `worker.repos.<repo>.image.registry`, else the workspace's `worker.image.registry`,
  else `fetch/1`, so an install that sets nothing per repo changes nothing. With
  no registry at all nothing in this namespace does anything, which is the
  "nothing changes" half of the K8 acceptance.

  ## Credential handling

  The `nodes.registry` password is stored Cloak-encrypted (`Arbiter.Settings`)
  and decrypted only here. A per-repo registry's login is a **workspace secret**
  named by `image.credentials_ref` (`"secret:KEY"`, `arb workspace secret set`)
  whose value is `user:password` (the token is the password: GHCR and GitLab both
  take a personal or deploy token that way). From here it travels to podman
  **only as a 0600 auth file**, one `auths` entry per host, inside a 0700
  directory that `with_authfile/3` removes when the callback returns
  (or raises): never on argv (`ps` shows argv host-wide), never in an
  environment variable, never in a log line. The struct derives `Inspect`
  without it, and `redact/2` scrubs it (and its base64 `user:password` form)
  from anything a tool printed before that text is stored or logged.

  ## Is the registry private?

  The repositories hold private dependency sources and the real `claude` binary,
  so `anonymous_read/3` asks the registry whether a stranger could read one back
  (`docs/design/remote-workers.md` §20.10). A repository that answers is refused
  by the publisher unless the registry sets `public_ok: true`.
  """

  alias Arbiter.Agents.CredentialsRef
  alias Arbiter.Settings
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Image.RepoConfig

  @derive {Inspect, except: [:password]}
  defstruct [
    :registry,
    :host,
    :username,
    :password,
    insecure?: false,
    public_ok: false,
    origin: :install
  ]

  @type t :: %__MODULE__{
          registry: String.t(),
          host: String.t(),
          username: String.t() | nil,
          password: String.t() | nil,
          insecure?: boolean(),
          public_ok: boolean(),
          origin: :install | :config
        }

  @digest_ref ~r/@sha256:[0-9a-f]{64}\z/
  @probe_timeout_ms 3_000

  @doc """
  The configured registry, or `:unset`. `opts[:config]` (a map with `:registry`,
  and optionally `:username`, `:password`, `:insecure?`) replaces the settings
  read, for tests and callers that already hold the values.
  """
  @spec fetch(keyword()) :: {:ok, t()} | :unset
  def fetch(opts \\ []) do
    raw =
      case Keyword.get(opts, :config) do
        %{} = config ->
          config

        _ ->
          %{
            registry: Settings.nodes_registry(),
            username: Settings.nodes_registry_username(),
            password: Settings.nodes_registry_password(),
            insecure?: Settings.nodes_registry_insecure?()
          }
      end

    case raw do
      %{registry: registry} when is_binary(registry) and registry != "" ->
        {:ok,
         %__MODULE__{
           registry: registry,
           host: host(registry),
           username: blank_to_nil(Map.get(raw, :username)),
           password: blank_to_nil(Map.get(raw, :password)),
           insecure?: Map.get(raw, :insecure?) == true
         }}

      _ ->
        :unset
    end
  end

  @doc """
  The registry `repo`'s images are pushed to, in `workspace` (a `Workspace`, any
  config-bearing map, or `nil`): `{:ok, t}`, `:unset` when neither the repo, the
  workspace nor `nodes.registry` names one, or `{:error, {:registry_credentials,
  ref, reason}}` when the configured `credentials_ref` names a secret the
  workspace does not have (`:secret_not_found`) or one that is not `user:password`
  (`:malformed`): a push that was meant to be authenticated is never made
  anonymously instead.

  `opts[:config]` replaces the install-wide read (`fetch/1`).
  """
  @spec resolve(term(), String.t() | nil, keyword()) ::
          {:ok, t()} | :unset | {:error, {:registry_credentials, String.t(), atom()}}
  def resolve(workspace, repo, opts \\ []) do
    case RepoConfig.resolve(workspace, repo) do
      %{registry: nil} ->
        fetch(opts)

      %{registry: registry} = image ->
        with {:ok, {user, password}} <- credentials(image.credentials_ref, workspace) do
          {:ok,
           %__MODULE__{
             registry: registry,
             host: host(registry),
             username: user,
             password: password,
             public_ok: image.public_ok,
             origin: :config
           }}
        end
    end
  end

  defp credentials(nil, _workspace), do: {:ok, {nil, nil}}

  defp credentials(ref, workspace) do
    secrets = CredentialsRef.embed_secrets(%{}, workspace_secrets(workspace))

    with {:ok, value} <- CredentialsRef.resolve(ref, secrets),
         [user, password] when user != "" and password != "" <-
           String.split(String.trim(value), ":", parts: 2) do
      {:ok, {user, password}}
    else
      {:secret_not_found, _} -> {:error, {:registry_credentials, ref, :secret_not_found}}
      _ -> {:error, {:registry_credentials, ref, :malformed}}
    end
  end

  defp workspace_secrets(%Workspace{} = workspace), do: Workspace.secrets_map(workspace)
  defp workspace_secrets(%{secrets: %{} = secrets}), do: secrets
  defp workspace_secrets(_), do: %{}

  defp host(registry), do: registry |> String.split("/", parts: 2) |> hd()

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @doc "`<registry>/<name>`: the repository an image is pushed to."
  @spec repository(t(), String.t()) :: String.t()
  def repository(%__MODULE__{registry: registry}, name), do: registry <> "/" <> name

  @doc "podman's TLS flag for this registry (`--tls-verify=false` when insecure)."
  @spec tls_flags(t()) :: [String.t()]
  def tls_flags(%__MODULE__{insecure?: true}), do: ["--tls-verify=false"]
  def tls_flags(%__MODULE__{}), do: []

  @doc "Whether `ref` names an image by `@sha256:<64 hex>`."
  @spec digest_pinned?(term()) :: boolean()
  def digest_pinned?(ref) when is_binary(ref), do: Regex.match?(@digest_ref, ref)
  def digest_pinned?(_), do: false

  @doc """
  Run `fun` with the path of a podman auth file holding the login of every
  registry in `registries` (one registry, or a list: a run that reads one
  registry and writes another gets one file with an `auths` entry per host), or
  with `nil` when none of them has a login (anonymous push). The file lives in a
  fresh 0700 directory under `scratch_root` and is removed afterwards, whether
  `fun` returns or raises.
  """
  @spec with_authfile(t() | [t()], Path.t(), (Path.t() | nil -> result)) :: result
        when result: term()
  def with_authfile(registries, scratch_root, fun) do
    logins =
      for %__MODULE__{host: host, username: user, password: pw} <- List.wrap(registries),
          is_binary(user) and is_binary(pw),
          into: %{},
          do: {host, %{"auth" => Base.encode64(user <> ":" <> pw)}}

    if map_size(logins) == 0,
      do: fun.(nil),
      else: with_auth_dir(logins, scratch_root, fun)
  end

  defp with_auth_dir(logins, scratch_root, fun) do
    dir =
      Path.join(
        scratch_root,
        "registry-auth-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    File.mkdir_p!(scratch_root)
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    path = Path.join(dir, "auth.json")

    try do
      File.write!(path, Jason.encode!(%{"auths" => logins}), [:exclusive])
      File.chmod!(path, 0o600)
      fun.(path)
    after
      File.rm_rf(dir)
    end
  end

  @doc "Scrub the password, and its base64 `user:password` form, of one or more registries from tool output."
  @spec redact(String.t(), t() | [t()]) :: String.t()
  def redact(text, registries) when is_binary(text) do
    registries
    |> List.wrap()
    |> Enum.flat_map(fn
      %__MODULE__{username: user, password: pw} when is_binary(pw) ->
        [pw] ++ if(user, do: [Base.encode64(user <> ":" <> pw)], else: [])

      _ ->
        []
    end)
    |> Enum.reduce(text, &String.replace(&2, &1, "[REDACTED]"))
  end

  def redact(text, _registries), do: text

  # -- probes -------------------------------------------------------------------

  @doc """
  Whether a registry answers at all: `GET /v2/`, where 200 (open) and 401 (auth
  required) both mean a registry is there. `:ok` or `{:error, reason}`.
  """
  @spec reachable(t(), keyword()) :: :ok | {:error, term()}
  def reachable(%__MODULE__{} = cfg, opts \\ []) do
    Enum.reduce_while(schemes(cfg), {:error, :unreachable}, fn scheme, _ ->
      case request("#{scheme}://#{cfg.host}/v2/", cfg, [], opts) do
        {:ok, %Req.Response{status: status}} when status in [200, 401] -> {:halt, :ok}
        {:ok, %Req.Response{status: status}} -> {:cont, {:error, {:http_status, status}}}
        {:error, reason} -> {:cont, {:error, reason}}
      end
    end)
  end

  @doc """
  Whether anyone can read `repository` (a name under the registry, e.g.
  `vstim/worker`) without a login: `:public`, `:private`, or `{:unknown, reason}`
  when the registry did not give a usable answer (never `:public` on a guess).

  An unauthenticated `GET /v2/<repository>/tags/list`. GitLab and GHCR answer
  that with a 401 and a bearer realm even for a public repository, so a 401 with
  a realm is followed by an *anonymous* token request for `repository:<name>:pull`
  and one retry with it: only a token that lists the tags makes it public.
  `opts[:req_options]` is merged into every request (a `:plug` in tests).
  """
  @spec anonymous_read(t(), String.t(), keyword()) :: :public | :private | {:unknown, term()}
  def anonymous_read(%__MODULE__{} = cfg, repository, opts \\ []) do
    path = repository_path(cfg, repository)

    Enum.reduce_while(schemes(cfg), {:unknown, :unreachable}, fn scheme, _ ->
      case read_tags("#{scheme}://#{cfg.host}", path, cfg, opts) do
        {:unknown, _} = unknown -> {:cont, unknown}
        answer -> {:halt, answer}
      end
    end)
  end

  defp repository_path(%__MODULE__{registry: registry}, repository) do
    case String.split(registry, "/", parts: 2) do
      [_host, prefix] -> prefix <> "/" <> repository
      _ -> repository
    end
  end

  defp read_tags(base, path, cfg, opts) do
    url = "#{base}/v2/#{path}/tags/list"

    case request(url, cfg, [], opts) do
      {:ok, %Req.Response{status: 200}} -> :public
      {:ok, %Req.Response{status: 401} = resp} -> challenge(resp, url, path, cfg, opts)
      {:ok, %Req.Response{status: status}} when status in [403, 404] -> :private
      {:ok, %Req.Response{status: status}} -> {:unknown, {:http_status, status}}
      {:error, reason} -> {:unknown, reason}
    end
  end

  defp challenge(resp, url, path, cfg, opts) do
    header = resp |> Req.Response.get_header("www-authenticate") |> Enum.join(", ")

    with "Bearer " <> params <- String.trim(header),
         %{"realm" => "http" <> _ = realm} = parsed <- parse_challenge(params) do
      token_params = [scope: "repository:#{path}:pull"]

      token_params =
        token_params ++ for(service <- List.wrap(parsed["service"]), do: {:service, service})

      with {:ok, token} <- anonymous_token(realm, token_params, cfg, opts) do
        case request(url, cfg, [auth: {:bearer, token}], opts) do
          {:ok, %Req.Response{status: 200}} -> :public
          {:ok, %Req.Response{status: status}} when status in [401, 403, 404] -> :private
          {:ok, %Req.Response{status: status}} -> {:unknown, {:http_status, status}}
          {:error, reason} -> {:unknown, reason}
        end
      end
    else
      _ -> :private
    end
  end

  defp anonymous_token(realm, params, cfg, opts) do
    case request(realm, cfg, [params: params], opts) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        case body["token"] || body["access_token"] do
          token when is_binary(token) and token != "" -> {:ok, token}
          _ -> :private
        end

      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        :private

      {:ok, %Req.Response{status: status}} ->
        {:unknown, {:http_status, status}}

      {:error, reason} ->
        {:unknown, reason}
    end
  end

  # `Bearer realm="…",service="…"` → %{"realm" => …, "service" => …}
  defp parse_challenge(params) do
    ~r/(\w+)="([^"]*)"/
    |> Regex.scan(params)
    |> Map.new(fn [_, key, value] -> {key, value} end)
  end

  defp schemes(%__MODULE__{insecure?: true}), do: ["https", "http"]
  defp schemes(%__MODULE__{}), do: ["https"]

  defp request(url, cfg, extra, opts) do
    transport = if cfg.insecure?, do: [transport_opts: [verify: :verify_none]], else: []

    Req.get(
      url,
      [
        retry: false,
        receive_timeout: @probe_timeout_ms,
        connect_options: [timeout: @probe_timeout_ms] ++ transport,
        redirect: false
      ] ++ extra ++ Keyword.get(opts, :req_options, [])
    )
  end
end
