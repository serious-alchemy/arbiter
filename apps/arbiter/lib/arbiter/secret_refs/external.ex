defmodule Arbiter.SecretRefs.External do
  @moduledoc """
  Resolves **external secret-manager references** — pointers to a secret that
  lives outside arbiter's disk footprint — into their value.

  ## Reference forms

    * `aws-sm:<secret-id>[#json-key]` — AWS Secrets Manager `GetSecretValue`.
      `<secret-id>` is a name or ARN; with `#json-key` the secret string is
      parsed as a JSON object and that string field is returned.
    * `aws-ssm:<parameter-name>` — AWS Systems Manager Parameter Store
      `GetParameter` with decryption (`SecureString`). `#json-key` works the
      same way.
    * `file:<path>` — a file's contents, trailing whitespace trimmed (systemd
      `LoadCredential=`, a tmpfs, a Kubernetes secret mount). No `#json-key`:
      the whole text after `file:` is the path.

  AWS auth comes from the ambient credential chain
  (`Arbiter.SecretRefs.AwsCredentials`): environment, container role, shared
  credentials file, EC2 instance role. The region comes from the ARN when the
  id is one, else `AWS_REGION` / `AWS_DEFAULT_REGION` / IMDS.
  `AWS_ENDPOINT_URL_SECRETS_MANAGER`, `AWS_ENDPOINT_URL_SSM` and
  `AWS_ENDPOINT_URL` override the endpoint (VPC endpoints, LocalStack).

  ## Handling of the values

  Resolution is lazy and cached **in memory only** (`Arbiter.SecretRefs.Cache`,
  ETS) for `ARBITER_SECRET_CACHE_TTL` seconds (default 300; `0` disables the
  cache). A failed refresh serves the last value rather than breaking a running
  system. Values are never logged or written to disk, error terms carry only the
  reference and a coarse reason (never a response body), and every cached value
  is added to the `Arbiter.Redaction` set via `cached_values/0`.

  ## Boot-time secrets

  `env_or_ref/1` is the one rule for a secret that can be given either inline
  or as a pointer: `NAME_REF` (a reference in the DSL above) is used when set,
  and wins over an inline `NAME`; otherwise `NAME`. A broken pointer is an error
  rather than a silent fall-back to the inline value, so a rotation never
  quietly keeps using the old secret. `env_or_ref!/1` raises, for `runtime.exs`
  and the Vault, which must fail loudly at boot.
  """

  alias Arbiter.SecretRefs.{AwsCredentials, Cache}

  require Logger

  @default_ttl_s 300
  @schemes [{"aws-sm:", :aws_sm}, {"aws-ssm:", :aws_ssm}, {"file:", :file}]

  @type parsed :: %{scheme: :aws_sm | :aws_ssm | :file, target: String.t(), key: String.t() | nil}
  @type reason :: term()

  @doc "True when `ref` is one of the external reference forms."
  @spec external?(term()) :: boolean()
  def external?(ref), do: parse(ref) != :error

  @doc "The scheme name of an external ref (aws-sm, aws-ssm or file), or nil."
  @spec scheme_name(term()) :: String.t() | nil
  def scheme_name(ref) when is_binary(ref) do
    Enum.find_value(@schemes, fn {prefix, _} ->
      if String.starts_with?(ref, prefix), do: String.trim_trailing(prefix, ":")
    end)
  end

  def scheme_name(_), do: nil

  @doc "Split a reference into scheme, target and optional JSON key."
  @spec parse(term()) :: {:ok, parsed()} | :error
  def parse(ref) when is_binary(ref) do
    Enum.find_value(@schemes, :error, fn {prefix, scheme} ->
      case ref do
        ^prefix <> rest -> build(scheme, rest)
        _ -> nil
      end
    end)
  end

  def parse(_), do: :error

  defp build(:file, rest) do
    if String.trim(rest) == "", do: :error, else: {:ok, %{scheme: :file, target: rest, key: nil}}
  end

  defp build(scheme, rest) do
    {target, key} =
      case String.split(rest, "#", parts: 2) do
        [t, k] when k != "" -> {t, k}
        [t | _] -> {t, nil}
      end

    if String.trim(target) == "",
      do: :error,
      else: {:ok, %{scheme: scheme, target: target, key: key}}
  end

  @doc "The cache key a reference is stored under."
  @spec cache_key(String.t()) :: term()
  def cache_key(ref), do: {:secret, ref}

  @doc "Every currently cached resolved value (for `Arbiter.Redaction`)."
  @spec cached_values() :: [String.t()]
  def cached_values, do: Cache.values(&match?({:secret, _}, &1))

  @doc """
  Resolve an external reference to its value.

  `{:error, reason}` carries no secret material. See `describe_error/1`.
  """
  @spec resolve(term()) :: {:ok, String.t()} | {:error, reason()}
  def resolve(ref) do
    case parse(ref) do
      :error -> {:error, :invalid_ref}
      {:ok, parsed} -> cached_fetch(ref, parsed)
    end
  end

  defp cached_fetch(ref, parsed) do
    key = cache_key(ref)
    cached = Cache.get(key)

    case cached do
      {:fresh, value} ->
        {:ok, value}

      _ ->
        case fetch(parsed) do
          {:ok, value} ->
            ttl = ttl_ms()
            if ttl > 0, do: Cache.put(key, value, ttl)
            {:ok, value}

          {:error, reason} ->
            serve_stale(cached, ref, reason)
        end
    end
  end

  defp serve_stale({:stale, value}, ref, reason) do
    Logger.warning(
      "secret ref #{ref} could not be refreshed (#{describe_error(reason)}); serving the previous value"
    )

    {:ok, value}
  end

  defp serve_stale(_cached, _ref, reason), do: {:error, reason}

  @doc """
  The cache TTL in milliseconds: `ARBITER_SECRET_CACHE_TTL` seconds (a
  non-negative integer), default #{@default_ttl_s}s.
  """
  @spec ttl_ms() :: non_neg_integer()
  def ttl_ms do
    case Integer.parse(System.get_env("ARBITER_SECRET_CACHE_TTL", "")) do
      {n, ""} when n >= 0 -> n * 1000
      _ -> @default_ttl_s * 1000
    end
  end

  @doc """
  Resolve a secret given inline as `NAME` or as a pointer in `NAME_REF`.

    * `{:ok, value}` — resolved (the pointer when `NAME_REF` is set, else `NAME`).
    * `:unset` — neither is set.
    * `{:error, ref, reason}` — `NAME_REF` is set but unusable.
  """
  @spec env_or_ref(String.t()) :: {:ok, String.t()} | :unset | {:error, String.t(), reason()}
  def env_or_ref(name) do
    case System.get_env(name <> "_REF") do
      ref when is_binary(ref) and ref != "" ->
        ref = String.trim(ref)

        case resolve(ref) do
          {:ok, value} -> {:ok, value}
          {:error, reason} -> {:error, ref, reason}
        end

      _ ->
        case System.get_env(name) do
          value when is_binary(value) and value != "" -> {:ok, value}
          _ -> :unset
        end
    end
  end

  @doc """
  Like `env_or_ref/1` but returns the value or `nil` (unset) and raises when
  `NAME_REF` is set but cannot be resolved. The message names the variable and
  the pointer, never a value.
  """
  @spec env_or_ref!(String.t()) :: String.t() | nil
  def env_or_ref!(name) do
    case env_or_ref(name) do
      {:ok, value} ->
        value

      :unset ->
        nil

      {:error, ref, reason} ->
        raise "#{name}_REF=#{ref} could not be resolved: #{describe_error(reason)}"
    end
  end

  @doc """
  The forgiving form of `env_or_ref/1` for an *optional* secret read at run time
  (the update check's `GITHUB_TOKEN`): the value, or `nil` when it is unset or
  its pointer cannot be resolved (logged as a warning naming the pointer only).
  """
  @spec env_value(String.t()) :: String.t() | nil
  def env_value(name) do
    case env_or_ref(name) do
      {:ok, value} ->
        value

      :unset ->
        nil

      {:error, ref, reason} ->
        Logger.warning("#{name}_REF=#{ref} could not be resolved: #{describe_error(reason)}")
        nil
    end
  end

  @doc "A short, secret-free description of a resolution failure."
  @spec describe_error(reason()) :: String.t()
  def describe_error(:invalid_ref),
    do: "not a recognised reference (expected aws-sm:, aws-ssm: or file:)"

  def describe_error(:no_aws_credentials), do: "no AWS credentials found in the ambient chain"
  def describe_error(:no_aws_region), do: "no AWS region (set AWS_REGION or use an ARN)"
  def describe_error(:empty), do: "the secret is empty"
  def describe_error(:not_json), do: "the secret is not a JSON object but a #json-key was given"

  def describe_error({:json_key_missing, key}),
    do: "no string field #{inspect(key)} in the secret"

  def describe_error({:file, posix}), do: "cannot read the file (#{inspect(posix)})"
  def describe_error({:http, status, ""}), do: "AWS answered HTTP #{status}"
  def describe_error({:http, status, type}), do: "AWS answered HTTP #{status} (#{type})"
  def describe_error({:request, reason}), do: "request failed (#{inspect(reason)})"
  def describe_error(other), do: "failed (#{inspect(other)})"

  # ---- fetchers -----------------------------------------------------------------

  defp fetch(%{scheme: :file, target: path}) do
    case File.read(path) do
      {:ok, body} -> non_empty(String.trim(body))
      {:error, posix} -> {:error, {:file, posix}}
    end
  end

  defp fetch(%{scheme: :aws_sm, target: id, key: key}) do
    with {:ok, body} <-
           aws_call(:secretsmanager, "secretsmanager.GetSecretValue", id, %{"SecretId" => id}),
         {:ok, value} <- secret_string(body) do
      pick_key(value, key)
    end
  end

  defp fetch(%{scheme: :aws_ssm, target: name, key: key}) do
    payload = %{"Name" => name, "WithDecryption" => true}

    with {:ok, body} <- aws_call(:ssm, "AmazonSSM.GetParameter", name, payload),
         {:ok, value} <- non_empty(get_in(body, ["Parameter", "Value"])) do
      pick_key(value, key)
    end
  end

  defp secret_string(%{"SecretString" => s}) when is_binary(s), do: non_empty(s)

  defp secret_string(%{"SecretBinary" => b}) when is_binary(b) do
    case Base.decode64(b) do
      {:ok, decoded} -> non_empty(decoded)
      :error -> {:error, :empty}
    end
  end

  defp secret_string(_), do: {:error, :empty}

  defp pick_key(value, nil), do: {:ok, value}

  defp pick_key(value, key) do
    case Jason.decode(value) do
      {:ok, %{} = map} ->
        case Map.get(map, key) do
          v when is_binary(v) and v != "" -> {:ok, v}
          _ -> {:error, {:json_key_missing, key}}
        end

      _ ->
        {:error, :not_json}
    end
  end

  defp non_empty(v) when is_binary(v) and v != "", do: {:ok, v}
  defp non_empty(_), do: {:error, :empty}

  # ---- AWS JSON-1.1 call -----------------------------------------------------------

  defp aws_call(service, target, id, payload) do
    opts = req_options()

    with {:ok, creds} <- AwsCredentials.fetch(opts),
         {:ok, region} <- region_for(id, opts) do
      ensure_http_started()

      sigv4 =
        Enum.reject(
          [
            access_key_id: creds.access_key_id,
            secret_access_key: creds.secret_access_key,
            token: creds.token,
            service: service,
            region: region
          ],
          fn {_k, v} -> is_nil(v) end
        )

      request =
        Keyword.merge(
          [
            method: :post,
            url: endpoint(service, region),
            headers: [
              {"x-amz-target", target},
              {"content-type", "application/x-amz-json-1.1"}
            ],
            body: Jason.encode!(payload),
            aws_sigv4: sigv4,
            retry: false,
            receive_timeout: 10_000,
            decode_body: false
          ],
          opts
        )

      case Req.request(request) do
        {:ok, %{status: 200, body: raw}} -> decode_body(raw)
        {:ok, %{status: status} = resp} -> {:error, {:http, status, error_type(resp)}}
        {:error, e} -> {:error, {:request, transport_reason(e)}}
      end
    end
  rescue
    e -> {:error, {:request, e.__struct__}}
  end

  defp decode_body(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, :empty}
    end
  end

  defp decode_body(%{} = map), do: {:ok, map}
  defp decode_body(_), do: {:error, :empty}

  # The AWS error type ("ResourceNotFoundException"), never the message body.
  defp error_type(%{body: raw, headers: headers}) do
    from_body =
      with raw when is_binary(raw) <- raw,
           {:ok, %{"__type" => type}} when is_binary(type) <- Jason.decode(raw) do
        type
      else
        _ -> nil
      end

    from_header =
      case headers do
        %{"x-amzn-errortype" => [type | _]} -> type
        _ -> nil
      end

    (from_body || from_header || "")
    |> String.split("#")
    |> List.last()
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "")
    |> String.slice(0, 80)
  end

  defp transport_reason(%{reason: reason}) when is_atom(reason), do: reason
  defp transport_reason(%{__struct__: mod}), do: mod

  defp region_for(id, opts) do
    case Regex.run(~r/^arn:[^:]*:[^:]*:([a-z0-9-]+):/, id) do
      [_, region] ->
        {:ok, region}

      _ ->
        case AwsCredentials.region(opts) do
          region when is_binary(region) -> {:ok, region}
          _ -> {:error, :no_aws_region}
        end
    end
  end

  defp endpoint(service, region) do
    {env_name, host_prefix} =
      case service do
        :secretsmanager -> {"AWS_ENDPOINT_URL_SECRETS_MANAGER", "secretsmanager"}
        :ssm -> {"AWS_ENDPOINT_URL_SSM", "ssm"}
      end

    [System.get_env(env_name), System.get_env("AWS_ENDPOINT_URL")]
    |> Enum.find(&(is_binary(&1) and &1 != ""))
    |> case do
      nil ->
        suffix =
          if String.starts_with?(region, "cn-"), do: "amazonaws.com.cn", else: "amazonaws.com"

        "https://#{host_prefix}.#{region}.#{suffix}/"

      url ->
        url
    end
  end

  defp req_options do
    :arbiter |> Application.get_env(__MODULE__, []) |> Keyword.get(:req_options, [])
  end

  # `runtime.exs` and release `eval` run before the application tree: start just
  # the HTTP client's own applications.
  defp ensure_http_started do
    _ = Application.ensure_all_started(:req)
    :ok
  end
end
