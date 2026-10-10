defmodule Arbiter.NodeAgent.K8s.Client do
  @moduledoc """
  The Kubernetes API client of the in-cluster agent (K3,
  `docs/design/remote-workers.md` k8s §3): `Req` against the API server, in-cluster
  service-account auth, and exactly the verbs the controller's RBAC grants on
  `pods` — list, watch, create, delete — plus the `pods/log` read and follow.
  No `exec`, no `attach`, no patch: there is nothing here the Role does not allow.

  ## Auth

  `in_cluster/1` reads the mounted service account
  (`/var/run/secrets/kubernetes.io/serviceaccount/{token,ca.crt,namespace}`) and
  `KUBERNETES_SERVICE_HOST`/`_PORT_HTTPS`. The token is a *file reference*, read
  again on every request: projected service-account tokens are short-lived and
  the kubelet rotates the file in place. The cluster CA is pinned through
  `connect_options` (no system trust store, no `verify_none`).

  ## Errors

  Every call returns `{:ok, _}` or `{:error, reason}`, never raises on an API or
  transport failure. Reasons: `:unauthorized` (401), `{:forbidden, message}`
  (403), `:not_found` (404), `:already_exists` (409 on create), `:conflict`
  (other 409), `:gone` (410), `{:invalid, message}` (422), `{:http, status,
  message}` (anything else), `{:transport, exception}`. `message` is the
  `Status.message` the server sent. Requests are **not retried** here: whoever
  owns the loop (the informer, the controller) owns the policy, and a blind retry
  of a `POST` is not safe.

  ## Streaming

  `watch_pods/5` and `follow_log/5` run in the caller's process and block until
  the stream ends. They are reduces: the handler gets each item and the
  accumulator and returns `{:cont, acc}` or `{:halt, acc}`; the call returns
  `{outcome, acc}` with the accumulator as the handler last left it, so a caller
  that sees a drop still knows how far it got (the informer resumes from there).
  Outcomes: `:closed` (the server ended the stream), `:halted`, `:gone` (watch
  only: the resourceVersion is too old, whether reported as an HTTP 410 or as an
  `ERROR` event), `{:error, reason}`.
  """

  alias Arbiter.NodeAgent.K8s.WatchStream

  @sa_dir "/var/run/secrets/kubernetes.io/serviceaccount"
  @default_watch_timeout_s 300
  # How much longer than the server-side watch timeout the socket may stay silent.
  @receive_slack_ms 30_000

  @enforce_keys [:base_url, :namespace]
  defstruct [:base_url, :namespace, :token, req_options: []]

  @type t :: %__MODULE__{
          base_url: String.t(),
          namespace: String.t(),
          token: nil | String.t() | {:file, Path.t()},
          req_options: keyword()
        }

  @type error :: term()

  @doc """
  A client for `:base_url` / `:namespace`. `:token` is a bearer token or `{:file,
  path}`; `:req_options` are merged into every `Req` request (tests pass plugs
  or `retry` here).
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      base_url: Keyword.fetch!(opts, :base_url),
      namespace: Keyword.fetch!(opts, :namespace),
      token: Keyword.get(opts, :token),
      req_options: Keyword.get(opts, :req_options, [])
    }
  end

  @doc """
  The client for the pod we are running in. Options: `:sa_dir` (default the
  standard mount) and `:env` (default `System.get_env/0`), both for tests.
  `{:error, :not_in_cluster}` when `KUBERNETES_SERVICE_HOST` is unset;
  `{:error, {:service_account, file, posix}}` when a mounted file is unreadable.
  """
  @spec in_cluster(keyword()) :: {:ok, t()} | {:error, term()}
  def in_cluster(opts \\ []) do
    sa_dir = Keyword.get(opts, :sa_dir, @sa_dir)
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    with {:ok, host} <- fetch_host(env),
         {:ok, _token} <- read_sa(sa_dir, "token"),
         {:ok, namespace} <- read_sa(sa_dir, "namespace"),
         ca = Path.join(sa_dir, "ca.crt"),
         {:ok, _ca} <- read_sa(sa_dir, "ca.crt") do
      port = env["KUBERNETES_SERVICE_PORT_HTTPS"] || env["KUBERNETES_SERVICE_PORT"] || "443"

      {:ok,
       new(
         base_url: "https://#{format_host(host)}:#{port}",
         namespace: String.trim(namespace),
         token: {:file, Path.join(sa_dir, "token")},
         req_options: [connect_options: [transport_opts: [cacertfile: ca]]]
       )}
    end
  end

  defp fetch_host(env) do
    case env["KUBERNETES_SERVICE_HOST"] do
      host when is_binary(host) and host != "" -> {:ok, host}
      _ -> {:error, :not_in_cluster}
    end
  end

  defp read_sa(dir, file) do
    case File.read(Path.join(dir, file)) do
      {:ok, content} -> {:ok, content}
      {:error, posix} -> {:error, {:service_account, file, posix}}
    end
  end

  defp format_host(host), do: if(String.contains?(host, ":"), do: "[#{host}]", else: host)

  @doc "A labels map to the `a=b,c=d` selector string (keys sorted)."
  @spec label_selector(%{optional(String.t()) => String.t()}) :: String.t()
  def label_selector(labels) do
    labels |> Enum.sort() |> Enum.map_join(",", fn {k, v} -> "#{k}=#{v}" end)
  end

  # --- list / create / delete -------------------------------------------------

  @doc """
  Lists pods, following `continue` tokens. Options: `:label_selector`, `:limit`
  (the page size). Returns `{:ok, %{items: [pod], resource_version: rv}}` where
  `rv` is the list's own resourceVersion — what a watch continues from.
  """
  @spec list_pods(t(), keyword()) ::
          {:ok, %{items: [map()], resource_version: String.t()}} | {:error, error()}
  def list_pods(client, opts \\ []) do
    params =
      [labelSelector: opts[:label_selector], limit: opts[:limit]]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    list_pages(client, params, [], nil)
  end

  defp list_pages(client, params, acc, continue) do
    page_params = if continue, do: Keyword.put(params, :continue, continue), else: params

    case request(client, :get, pods_path(client), params: page_params) do
      {:ok, %{"items" => items, "metadata" => meta}} ->
        acc = [items | acc]

        case meta["continue"] do
          token when is_binary(token) and token != "" ->
            list_pages(client, params, acc, token)

          _ ->
            {:ok,
             %{
               items: acc |> Enum.reverse() |> Enum.concat(),
               resource_version: meta["resourceVersion"]
             }}
        end

      {:ok, other} ->
        {:error, {:unexpected_body, other}}

      {:error, _} = error ->
        error
    end
  end

  @doc "Creates a pod from a manifest map. `{:error, :already_exists}` on a name clash."
  @spec create_pod(t(), map()) :: {:ok, map()} | {:error, error()}
  def create_pod(client, manifest) do
    case request(client, :post, pods_path(client), json: manifest) do
      {:error, :conflict} -> {:error, :already_exists}
      other -> other
    end
  end

  @doc """
  Deletes a pod. Options: `:grace_period_seconds` (0 is sent as 0: SIGKILL
  immediately), `:uid` (a precondition: only delete *that* incarnation).
  `{:ok, :deleted}`, or `{:ok, :not_found}` when it was already gone — deleting is
  idempotent for the caller.
  """
  @spec delete_pod(t(), String.t(), keyword()) :: {:ok, :deleted | :not_found} | {:error, error()}
  def delete_pod(client, name, opts \\ []) do
    body =
      %{"propagationPolicy" => "Background"}
      |> put_unless_nil("gracePeriodSeconds", opts[:grace_period_seconds])
      |> put_unless_nil("preconditions", opts[:uid] && %{"uid" => opts[:uid]})

    case request(client, :delete, pods_path(client, name), json: body) do
      {:ok, _} -> {:ok, :deleted}
      {:error, :not_found} -> {:ok, :not_found}
      {:error, _} = error -> error
    end
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  # --- resourcequotas and the Lease (K5) ----------------------------------------

  @doc """
  The namespace's `ResourceQuota` objects (`get/list` on `resourcequotas`, the only
  verb the Role grants there). The headroom the controller reports is computed from
  them, see `Arbiter.NodeAgent.K8s.Quota`.
  """
  @spec list_resource_quotas(t()) :: {:ok, [map()]} | {:error, error()}
  def list_resource_quotas(client) do
    case request(client, :get, "/api/v1/namespaces/#{client.namespace}/resourcequotas", []) do
      {:ok, %{"items" => items}} when is_list(items) -> {:ok, items}
      {:ok, _} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  @doc """
  A `coordination.k8s.io` Lease by name. The install pre-creates the single
  `arbiter-controller` Lease, and the Role grants `get`/`update` on that name only,
  so there is no create here.
  """
  @spec get_lease(t(), String.t()) :: {:ok, map()} | {:error, error()}
  def get_lease(client, name), do: request(client, :get, lease_path(client, name), [])

  @doc """
  Replaces a Lease (`PUT`, the object as `get_lease/2` returned it with the changes).
  The `resourceVersion` inside is the precondition: `{:error, :conflict}` when
  someone else wrote first, which is how two controllers find out about each other.
  """
  @spec update_lease(t(), map()) :: {:ok, map()} | {:error, error()}
  def update_lease(client, lease) do
    name = get_in(lease, ["metadata", "name"])
    request(client, :put, lease_path(client, name), json: lease)
  end

  defp lease_path(client, name),
    do:
      "/apis/coordination.k8s.io/v1/namespaces/#{client.namespace}/leases/" <>
        URI.encode(name, &URI.char_unreserved?/1)

  # --- the controller's own Deployment (K9 self-upgrade) -------------------------------

  @doc """
  An `apps/v1` Deployment by name. The Role grants `get` on `deployments/arbiter-controller`
  only (the owner-reference UID, and the image `Arbiter.NodeAgent.K8s.SelfUpgrade` compares).
  """
  @spec get_deployment(t(), String.t()) :: {:ok, map()} | {:error, error()}
  def get_deployment(client, name), do: request(client, :get, deployment_path(client, name), [])

  @doc """
  A strategic merge patch (`patch` is the decoded body) of a Deployment. The Role grants
  `patch` on `deployments/arbiter-controller` only, and only when `rbac.selfUpgrade` is on:
  anything else is `{:error, {:forbidden, message}}`.
  """
  @spec patch_deployment(t(), String.t(), map()) :: {:ok, map()} | {:error, error()}
  def patch_deployment(client, name, patch) do
    request(client, :patch, deployment_path(client, name),
      body: Jason.encode!(patch),
      headers: [{"content-type", "application/strategic-merge-patch+json"}]
    )
  end

  defp deployment_path(client, name),
    do:
      "/apis/apps/v1/namespaces/#{client.namespace}/deployments/" <>
        URI.encode(name, &URI.char_unreserved?/1)

  # --- logs -------------------------------------------------------------------

  @doc """
  A non-follow log read. Options: `:container`, `:timestamps`, `:since_time` (RFC
  3339), `:tail_lines`. Returns the body as a binary.
  """
  @spec read_log(t(), String.t(), keyword()) :: {:ok, binary()} | {:error, error()}
  def read_log(client, pod, opts \\ []) do
    case request(client, :get, pods_path(client, pod) <> "/log", params: log_params(opts, false)) do
      {:ok, body} when is_binary(body) -> {:ok, body}
      {:ok, other} -> {:ok, Jason.encode!(other)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Follows a pod's log: `fun.(chunk, acc)` per body chunk (arbitrary boundaries,
  not lines), returning `{outcome, acc}`. Same options as `read_log/3`. The
  `timestamps` prefix, line framing and the resume cursor are the caller's.
  """
  @spec follow_log(
          t(),
          String.t(),
          acc,
          (binary(), acc -> {:cont, acc} | {:halt, acc}),
          keyword()
        ) ::
          {:closed | :halted | {:error, error()}, acc}
        when acc: term()
  def follow_log(client, pod, acc, fun, opts \\ []) do
    handle = fn chunk, state ->
      case fun.(chunk, state.acc) do
        {:cont, acc} -> {:cont, %{state | acc: acc}}
        {:halt, acc} -> {:halt, %{state | acc: acc, halted?: true}}
      end
    end

    {outcome, state} =
      stream(
        client,
        pods_path(client, pod) <> "/log",
        log_params(opts, true),
        [],
        %{acc: acc, halted?: false},
        handle
      )

    case outcome do
      :closed when state.halted? -> {:halted, state.acc}
      outcome -> {outcome, state.acc}
    end
  end

  defp log_params(opts, follow?) do
    [
      container: opts[:container],
      follow: if(follow?, do: "true"),
      timestamps: if(opts[:timestamps], do: "true"),
      sinceTime: opts[:since_time],
      tailLines: opts[:tail_lines]
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  # --- watch ------------------------------------------------------------------

  @doc """
  Watches pods from `resource_version`, with bookmarks. `fun.(event, acc)` gets
  `{:added | :modified | :deleted | :bookmark, pod}` and returns `{:cont, acc}` or
  `{:halt, acc}`. Options: `:label_selector`, `:timeout_s` (the server closes the
  watch after this long; default #{@default_watch_timeout_s}).

  Returns `{:closed | :halted | :gone | {:error, reason}, acc}`. `:gone` means the
  resourceVersion has been compacted: relist. A partial trailing event is
  dropped, never delivered.
  """
  @spec watch_pods(
          t(),
          String.t(),
          acc,
          (WatchStream.event(), acc -> {:cont, acc} | {:halt, acc}),
          keyword()
        ) ::
          {:closed | :halted | :gone | {:error, error()}, acc}
        when acc: term()
  def watch_pods(client, resource_version, acc, fun, opts \\ []) do
    timeout_s = Keyword.get(opts, :timeout_s, @default_watch_timeout_s)

    params =
      [
        watch: "true",
        resourceVersion: resource_version,
        allowWatchBookmarks: "true",
        timeoutSeconds: timeout_s,
        labelSelector: opts[:label_selector]
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    initial = %{acc: acc, decoder: WatchStream.new(), outcome: nil}

    handle = fn chunk, state ->
      {events, decoder} = WatchStream.feed(state.decoder, chunk)
      deliver(events, %{state | decoder: decoder}, fun)
    end

    {outcome, state} =
      stream(
        client,
        pods_path(client),
        params,
        [receive_timeout: timeout_s * 1000 + @receive_slack_ms],
        initial,
        handle
      )

    case {outcome, state.outcome} do
      {:closed, nil} -> {:closed, state.acc}
      {:closed, :halted} -> {:halted, state.acc}
      {:closed, other} -> {other, state.acc}
      {error, _} -> {error, state.acc}
    end
  end

  defp deliver([], state, _fun), do: {:cont, state}

  defp deliver([{:error, status} | _], state, _fun) do
    outcome =
      if status["code"] == 410,
        do: :gone,
        else: {:error, {:watch_error, status["code"], status["message"]}}

    {:halt, %{state | outcome: outcome}}
  end

  defp deliver([{:bad_event, line} | _], state, _fun),
    do: {:halt, %{state | outcome: {:error, {:bad_event, line}}}}

  defp deliver([event | rest], state, fun) do
    case fun.(event, state.acc) do
      {:cont, acc} -> deliver(rest, %{state | acc: acc}, fun)
      {:halt, acc} -> {:halt, %{state | acc: acc, outcome: :halted}}
    end
  end

  # --- plumbing ---------------------------------------------------------------

  defp pods_path(client), do: "/api/v1/namespaces/#{client.namespace}/pods"

  defp pods_path(client, name),
    do: pods_path(client) <> "/" <> URI.encode(name, &URI.char_unreserved?/1)

  # A plain request/response.
  defp request(client, method, path, opts) do
    with {:ok, req} <- build(client, method, path, opts) do
      case Req.request(req) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 -> {:ok, body}
        {:ok, resp} -> {:error, api_error(resp.status, resp.body)}
        {:error, exception} -> {:error, {:transport, exception}}
      end
    end
  end

  # A streaming request: `handle.(chunk, state)` per body chunk. Returns
  # `{:closed | :gone | {:error, reason}, state}`; a halt from `handle` is
  # `:closed` too (the caller reads its own state to tell why). `state` is
  # whatever the handler last returned, also when the stream fails.
  defp stream(client, path, params, opts, initial, handle) do
    req_opts = [params: params] ++ Keyword.take(opts, [:receive_timeout])

    # Req runs the `into` callback in this process, so the handler's state is kept
    # here and survives a connection that dies mid-stream, when Req returns only
    # the error and drops the response (the informer resumes from that state).
    key = {__MODULE__, :stream, make_ref()}
    Process.put(key, initial)

    result =
      with {:ok, req} <- build(client, :get, path, req_opts) do
        into = fn {:data, data}, {req, resp} ->
          if resp.status in 200..299 do
            {verdict, state} = handle.(data, Process.get(key))
            Process.put(key, state)
            {verdict, {req, resp}}
          else
            body = Req.Response.get_private(resp, :error_body, "") <> data
            {:cont, {req, Req.Response.put_private(resp, :error_body, body)}}
          end
        end

        case Req.request(req, into: into) do
          {:ok, resp} -> {:ok, resp}
          {:error, exception} -> {:error, {:transport, exception}}
        end
      end

    state = Process.delete(key)

    case result do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:closed, state}

      {:ok, resp} ->
        body = Req.Response.get_private(resp, :error_body, "")
        {outcome_for(api_error(resp.status, decode_body(body))), state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp outcome_for(:gone), do: :gone
  defp outcome_for(reason), do: {:error, reason}

  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp build(client, method, path, opts) do
    with {:ok, token} <- bearer(client) do
      {params, opts} = Keyword.pop(opts, :params)
      {json, opts} = Keyword.pop(opts, :json)

      req =
        Req.new(
          [method: method, base_url: client.base_url, url: path, retry: false]
          |> Keyword.merge(if(token, do: [auth: {:bearer, token}], else: []))
          |> Keyword.merge(if(params, do: [params: params], else: []))
          |> Keyword.merge(if(json, do: [json: json], else: []))
          |> Keyword.merge(client.req_options)
          |> Keyword.merge(opts)
        )

      {:ok, req}
    end
  end

  defp bearer(%{token: nil}), do: {:ok, nil}
  defp bearer(%{token: token}) when is_binary(token), do: {:ok, token}

  defp bearer(%{token: {:file, path}}) do
    case File.read(path) do
      {:ok, token} -> {:ok, String.trim(token)}
      {:error, posix} -> {:error, {:service_account, Path.basename(path), posix}}
    end
  end

  defp api_error(401, _), do: :unauthorized
  defp api_error(403, body), do: {:forbidden, message(body)}
  defp api_error(404, _), do: :not_found
  defp api_error(409, _), do: :conflict
  defp api_error(410, _), do: :gone
  defp api_error(422, body), do: {:invalid, message(body)}
  defp api_error(status, body), do: {:http, status, message(body)}

  defp message(%{"message" => message}) when is_binary(message), do: message
  defp message(body) when is_binary(body), do: body
  defp message(body), do: inspect(body)
end
