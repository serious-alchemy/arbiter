defmodule Arbiter.NodeAgent.K8s.Credential do
  @moduledoc """
  A cluster controller's node credential (`docs/design/remote-workers.md` K§2.4 step 1,
  K§12; ticket K14). The `arbn_<id>.<secret>` credential is the only standing secret a
  cluster node holds for the primary, and it lives in exactly one place: the Secret
  `arbiter-node-credential` (key `credential`), which only the controller's Role may
  `get`/`update`. It is never written to the controller's disk, an env var or a log.

  `obtain/2` is what the boot does:

    1. **Later boots** read the Secret and use what is there.
    2. **The first boot** finds the install's empty placeholder, reads the operator's join
       token (`/etc/arb/join/token`, the optional `arbiter-join` Secret), redeems it at
       `POST /nodes/enroll` (`kind: cluster`, the node name, `k8s_version`, `proto`,
       `agent_version`) and writes the answer to the Secret. The join Secret is then spent;
       the operator may delete it (the controller deliberately has no verb for that).

  A credential that was enrolled but could not be stored is handed back in the error
  (`{:error, {:store_failed, reason, credential}}`): the token is spent, so the caller
  keeps the credential and retries `store/2`, never the enrolment. A stored value that is
  not a credential, or an API error reading the Secret, is an error too, never a reason to
  enrol again.

  Options of `obtain/2`: `:primary_url` (required), `:token_file`, `:name`,
  `:k8s_version`, `:agent_version`, `:req_options` (merged into the enrol request: the
  proxy, test plugs).
  """

  alias Arbiter.NodeAgent.Config
  alias Arbiter.NodeAgent.K8s.Client

  @secret "arbiter-node-credential"
  @key "credential"
  @token_file "/etc/arb/join/token"
  @credential_re ~r/\Aarbn_[^.\s]+\.\S+\z/

  @type error ::
          :no_join_token
          | :credential_malformed
          | :already_stored
          | {:enroll_refused, non_neg_integer(), String.t()}
          | {:enroll_failed, term()}
          | {:store_failed, term(), String.t()}
          | term()

  @doc "The stored credential, or enrol with the join token and store it (see the moduledoc)."
  @spec obtain(Client.t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def obtain(%Client{} = client, opts) do
    case read(client) do
      {:ok, credential} -> {:ok, credential}
      :none -> enroll_and_store(client, opts)
      {:error, _} = error -> error
    end
  end

  @doc "The credential in the Secret: `{:ok, credential}`, `:none` when it is empty."
  @spec read(Client.t()) :: {:ok, String.t()} | :none | {:error, term()}
  def read(%Client{} = client) do
    with {:ok, secret} <- Client.get_secret(client, @secret) do
      case secret["data"] do
        %{@key => encoded} -> decode(encoded)
        _ -> :none
      end
    end
  end

  @doc """
  Write `credential` into the Secret (an update of the install's placeholder, with the
  `resourceVersion` it read). The same credential already there is `:ok`; a different one
  is `{:error, :already_stored}`: a credential is never replaced behind the operator's back.
  """
  @spec store(Client.t(), String.t()) :: :ok | {:error, term()}
  def store(%Client{} = client, credential) do
    with {:ok, secret} <- Client.get_secret(client, @secret) do
      case read_data(secret) do
        {:ok, ^credential} ->
          :ok

        {:ok, _other} ->
          {:error, :already_stored}

        _empty ->
          data = Map.put(secret["data"] || %{}, @key, Base.encode64(credential))

          case Client.update_secret(client, Map.put(secret, "data", data)) do
            {:ok, _} -> :ok
            {:error, _} = error -> error
          end
      end
    end
  end

  defp read_data(secret) do
    case secret["data"] do
      %{@key => encoded} -> decode(encoded)
      _ -> :none
    end
  end

  defp decode(encoded) do
    with {:ok, text} <- Base.decode64(encoded),
         credential = String.trim(text),
         true <- Regex.match?(@credential_re, credential) do
      {:ok, credential}
    else
      _ -> {:error, :credential_malformed}
    end
  end

  defp enroll_and_store(client, opts) do
    with {:ok, token} <- join_token(Keyword.get(opts, :token_file, @token_file)),
         {:ok, credential} <- enroll(token, opts) do
      case store(client, credential) do
        :ok -> {:ok, credential}
        {:error, reason} -> {:error, {:store_failed, reason, credential}}
      end
    end
  end

  defp join_token(path) do
    case File.read(path) do
      {:ok, text} ->
        case String.trim(text) do
          "" -> {:error, :no_join_token}
          token -> {:ok, token}
        end

      {:error, _} ->
        {:error, :no_join_token}
    end
  end

  defp enroll(token, opts) do
    body =
      %{
        "token" => token,
        "kind" => "cluster",
        "proto" => Config.proto(),
        "agent_version" => Keyword.get_lazy(opts, :agent_version, &Arbiter.Version.app_version/0)
      }
      |> put_present("name", opts[:name])
      |> put_present("k8s_version", opts[:k8s_version])

    url = String.trim_trailing(Keyword.fetch!(opts, :primary_url), "/") <> "/nodes/enroll"

    request =
      Keyword.merge(
        [
          url: url,
          json: body,
          headers: [{"accept", "application/json"}],
          receive_timeout: 30_000,
          retry: false
        ],
        Keyword.get(opts, :req_options, [])
      )

    case Req.post(request) do
      {:ok, %Req.Response{status: 200, body: %{"credential" => credential}}}
      when is_binary(credential) ->
        if Regex.match?(@credential_re, credential),
          do: {:ok, credential},
          else: {:error, {:enroll_refused, 200, "the answer carries no node credential"}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:enroll_refused, status, message(body)}}

      {:error, exception} ->
        {:error, {:enroll_failed, exception}}
    end
  end

  defp message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp message(body) when is_binary(body), do: String.slice(body, 0, 200)
  defp message(body), do: inspect(body, limit: 5, printable_limit: 200)

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
