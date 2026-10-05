defmodule Arbiter.Grok.Oidc do
  @moduledoc """
  The OIDC `refresh_token` grant grok's login uses (bd-9p4lx9): discover the
  issuer's `token_endpoint`, post `grant_type=refresh_token` as a public client
  (`client_id`, no secret), return the rotated tokens.

  Only `Arbiter.Grok.CredentialBroker` calls this, and only ever for the
  canonical credential, so a refresh happens in exactly one place.

  ## Outcomes

    * `{:ok, rotated}` — `access_token`, `refresh_token` (the issuer's new one,
      or the old one when it did not rotate) and `expires_at`.
    * `{:error, {:permanent, code}}` — the issuer refused the grant with an
      OAuth error that retrying cannot fix (`invalid_grant`,
      `invalid_client`, `unauthorized_client`): the operator has to log in
      again. `code` is the OAuth error string, never a token.
    * `{:error, {:transient, why}}` — a network failure, a 5xx/429, an
      unparseable response. Retrying later is correct and the credential is
      not known to be dead.

  There is no HTTP retry here: a refresh that the issuer processed but whose
  response was lost has already rotated the token, so a blind second POST
  would only turn a transient fault into an `invalid_grant`.

  No error value carries a request or response body, so a token cannot reach
  a log through one.
  """

  @permanent ~w(invalid_grant invalid_client unauthorized_client)
  @default_expires_in 3600

  @type rotated :: Arbiter.Grok.CredentialStore.rotated()

  @spec refresh(Arbiter.Grok.CredentialStore.creds(), DateTime.t(), keyword()) ::
          {:ok, rotated()} | {:error, {:permanent, String.t()} | {:transient, term()}}
  def refresh(
        %{issuer: issuer, client_id: client_id} = creds,
        %DateTime{} = now,
        req_options \\ []
      ) do
    with {:ok, endpoint} <- token_endpoint(issuer, req_options),
         {:ok, body} <- post_grant(endpoint, creds.refresh_token, client_id, req_options) do
      parse(body, creds.refresh_token, now)
    end
  end

  defp token_endpoint(issuer, req_options) do
    url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

    case request(:get, url, req_options, []) do
      {:ok, %Req.Response{status: 200, body: %{"token_endpoint" => endpoint}}}
      when is_binary(endpoint) ->
        {:ok, endpoint}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:transient, {:discovery_http, status}}}

      {:error, reason} ->
        {:error, {:transient, transport(reason)}}
    end
  end

  defp post_grant(endpoint, refresh_token, client_id, req_options) do
    form =
      [grant_type: "refresh_token", refresh_token: refresh_token] ++
        if(client_id, do: [client_id: client_id], else: [])

    case request(:post, endpoint, req_options, form: form) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 200}} ->
        {:error, {:transient, :bad_response}}

      {:ok, %Req.Response{status: status, body: body}} when status in [400, 401] ->
        classify_error(status, body)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:transient, {:http, status}}}

      {:error, reason} ->
        {:error, {:transient, transport(reason)}}
    end
  end

  defp classify_error(status, %{"error" => code}) when is_binary(code) do
    if code in @permanent,
      do: {:error, {:permanent, code}},
      else: {:error, {:transient, {:http, status}}}
  end

  defp classify_error(status, _body), do: {:error, {:transient, {:http, status}}}

  defp parse(%{"access_token" => access} = body, old_refresh, now)
       when is_binary(access) and access != "" do
    refresh =
      case body["refresh_token"] do
        token when is_binary(token) and token != "" -> token
        _ -> old_refresh
      end

    expires_in =
      case body["expires_in"] do
        seconds when is_integer(seconds) and seconds > 0 -> seconds
        _ -> @default_expires_in
      end

    {:ok,
     %{
       access_token: access,
       refresh_token: refresh,
       expires_at: DateTime.add(now, expires_in, :second)
     }}
  end

  defp parse(_body, _old_refresh, _now), do: {:error, {:transient, :bad_response}}

  defp request(method, url, req_options, opts) do
    [method: method, url: url, retry: false, receive_timeout: 15_000]
    |> Keyword.merge(opts)
    |> Keyword.merge(req_options)
    |> Req.request()
  end

  # `Req` transport exceptions carry only the reason atom/struct, but keep the
  # value to a bare atom anyway so nothing request-shaped is ever stored.
  defp transport(%{reason: reason}) when is_atom(reason), do: reason
  defp transport(_), do: :transport
end
