defmodule Arbiter.SecretRefs.AwsCredentials do
  @moduledoc """
  A small, dependency-free slice of the AWS default credential chain, enough to
  call Secrets Manager / SSM from the host arbiter runs on.

  Resolution order (first hit wins):

    1. `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (+ `AWS_SESSION_TOKEN`).
    2. ECS / EKS container credentials
       (`AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` or `_FULL_URI`).
    3. The shared credentials file (`AWS_SHARED_CREDENTIALS_FILE`, default
       `~/.aws/credentials`, profile `AWS_PROFILE` or `default`).
    4. EC2 instance-role credentials through IMDSv2 (skipped when
       `AWS_EC2_METADATA_DISABLED=true`).

  Short-lived credentials (container / instance role, with an `Expiration`) are
  cached in `Arbiter.SecretRefs.Cache` until shortly before they expire. Nothing
  here is logged or written to disk.
  """

  alias Arbiter.SecretRefs.Cache

  @imds "http://169.254.169.254"
  @cache_key {:aws_credentials}
  @expiry_margin_ms 5 * 60 * 1000

  @type creds :: %{
          access_key_id: String.t(),
          secret_access_key: String.t(),
          token: String.t() | nil
        }

  @doc "Resolve credentials; `req_options` are merged into every HTTP call (test seam)."
  @spec fetch(keyword()) :: {:ok, creds()} | {:error, :no_aws_credentials}
  def fetch(req_options \\ []) do
    case Cache.get(@cache_key) do
      {:fresh, creds} -> {:ok, creds}
      _ -> chain(req_options)
    end
  end

  @doc "The region to use when the ref itself names none: env, then IMDS."
  @spec region(keyword()) :: String.t() | nil
  def region(req_options \\ []) do
    blank_to_nil(System.get_env("AWS_REGION")) ||
      blank_to_nil(System.get_env("AWS_DEFAULT_REGION")) ||
      imds_region(req_options)
  end

  defp chain(opts) do
    case from_env() || from_container(opts) || from_shared_file() || from_imds(opts) do
      {creds, ttl_ms} ->
        if ttl_ms > 0, do: Cache.put(@cache_key, creds, ttl_ms)
        {:ok, creds}

      nil ->
        {:error, :no_aws_credentials}
    end
  end

  defp from_env do
    with id when is_binary(id) <- blank_to_nil(System.get_env("AWS_ACCESS_KEY_ID")),
         secret when is_binary(secret) <- blank_to_nil(System.get_env("AWS_SECRET_ACCESS_KEY")) do
      {%{
         access_key_id: id,
         secret_access_key: secret,
         token: blank_to_nil(System.get_env("AWS_SESSION_TOKEN"))
       }, 0}
    else
      _ -> nil
    end
  end

  defp from_container(opts) do
    url =
      case {blank_to_nil(System.get_env("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI")),
            blank_to_nil(System.get_env("AWS_CONTAINER_CREDENTIALS_FULL_URI"))} do
        {rel, _} when is_binary(rel) -> "http://169.254.170.2" <> rel
        {_, full} when is_binary(full) -> full
        _ -> nil
      end

    with url when is_binary(url) <- url,
         {:ok, %{status: 200, body: %{} = body}} <-
           http(:get, url, container_auth_headers(), nil, opts) do
      parse_json_credentials(body)
    else
      _ -> nil
    end
  end

  defp container_auth_headers do
    case blank_to_nil(System.get_env("AWS_CONTAINER_AUTHORIZATION_TOKEN")) do
      nil -> []
      token -> [{"authorization", token}]
    end
  end

  defp from_shared_file do
    path =
      blank_to_nil(System.get_env("AWS_SHARED_CREDENTIALS_FILE")) ||
        Path.join(System.get_env("HOME") || "", ".aws/credentials")

    profile = blank_to_nil(System.get_env("AWS_PROFILE")) || "default"

    with {:ok, body} <- File.read(path),
         %{"aws_access_key_id" => id, "aws_secret_access_key" => secret} = section
         when id != "" and secret != "" <- parse_ini(body, profile) do
      {%{access_key_id: id, secret_access_key: secret, token: section["aws_session_token"]}, 0}
    else
      _ -> nil
    end
  end

  @doc false
  # Minimal INI reader: `[profile]` headers, `key = value` lines, `#`/`;` comments.
  @spec parse_ini(String.t(), String.t()) :: map()
  def parse_ini(body, profile) do
    body
    |> String.split(["\r\n", "\n"])
    |> Enum.reduce({nil, %{}}, fn line, {section, acc} ->
      ini_line(String.trim(line), profile, section, acc)
    end)
    |> elem(1)
  end

  defp ini_line(line, profile, section, acc) do
    cond do
      line == "" or String.starts_with?(line, ["#", ";"]) ->
        {section, acc}

      String.starts_with?(line, "[") and String.ends_with?(line, "]") ->
        name = line |> String.slice(1..-2//1) |> String.trim()
        {String.replace_prefix(name, "profile ", ""), acc}

      section == profile ->
        case String.split(line, "=", parts: 2) do
          [k, v] -> {section, Map.put(acc, String.trim(k), String.trim(v))}
          _ -> {section, acc}
        end

      true ->
        {section, acc}
    end
  end

  defp from_imds(opts) do
    base = @imds <> "/latest/meta-data/iam/security-credentials/"

    with false <- imds_disabled?(),
         {:ok, token} <- imds_token(opts),
         headers = [{"x-aws-ec2-metadata-token", token}],
         {:ok, %{status: 200, body: roles}} when is_binary(roles) <-
           http(:get, base, headers, nil, opts),
         [role | _] <- String.split(roles, ["\n", "\r"], trim: true),
         {:ok, %{status: 200, body: %{} = body}} <- http(:get, base <> role, headers, nil, opts) do
      parse_json_credentials(body)
    else
      _ -> nil
    end
  end

  defp imds_disabled?, do: System.get_env("AWS_EC2_METADATA_DISABLED") in ["true", "TRUE", "1"]

  defp imds_token(opts) do
    headers = [{"x-aws-ec2-metadata-token-ttl-seconds", "21600"}]

    case http(:put, @imds <> "/latest/api/token", headers, "", opts) do
      {:ok, %{status: 200, body: token}} when is_binary(token) and token != "" -> {:ok, token}
      _ -> :error
    end
  end

  defp imds_region(opts) do
    with false <- imds_disabled?(),
         {:ok, token} <- imds_token(opts),
         {:ok, %{status: 200, body: region}} when is_binary(region) and region != "" <-
           http(
             :get,
             @imds <> "/latest/meta-data/placement/region",
             [{"x-aws-ec2-metadata-token", token}],
             nil,
             opts
           ) do
      String.trim(region)
    else
      _ -> nil
    end
  end

  defp parse_json_credentials(%{"AccessKeyId" => id, "SecretAccessKey" => secret} = body)
       when is_binary(id) and is_binary(secret) do
    token = body["Token"] || body["SessionToken"]

    ttl_ms =
      with exp when is_binary(exp) <- body["Expiration"],
           {:ok, dt, _} <- DateTime.from_iso8601(exp) do
        max(DateTime.diff(dt, DateTime.utc_now(), :millisecond) - @expiry_margin_ms, 0)
      else
        _ -> 0
      end

    {%{access_key_id: id, secret_access_key: secret, token: token}, ttl_ms}
  end

  defp parse_json_credentials(_), do: nil

  defp http(method, url, headers, body, opts) do
    base = [
      method: method,
      url: url,
      headers: headers,
      retry: false,
      receive_timeout: 2_000,
      connect_options: [timeout: 1_000],
      decode_body: false
    ]

    base = if body, do: Keyword.put(base, :body, body), else: base

    # The metadata and container endpoints answer JSON without always sending a
    # JSON content type, so decode by hand.
    case Req.request(Keyword.merge(base, opts)) do
      {:ok, %{body: raw} = resp} when is_binary(raw) ->
        case Jason.decode(raw) do
          {:ok, %{} = decoded} -> {:ok, %{resp | body: decoded}}
          _ -> {:ok, resp}
        end

      other ->
        other
    end
  rescue
    _ -> :error
  end

  defp blank_to_nil(v) when is_binary(v) and v != "", do: v
  defp blank_to_nil(_), do: nil
end
