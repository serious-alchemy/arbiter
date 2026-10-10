defmodule Arbiter.Test.FakeK8sApi do
  @moduledoc """
  A fake Kubernetes API server for the K3 tests: a `GenServer` holding the pods
  of one namespace plus an event history, served over HTTP by `Bandit` through
  `Arbiter.Test.FakeK8sApi.Plug`. It speaks just enough of the real wire format
  to exercise the client and informer honestly:

    * `GET pods` with `labelSelector` (equality only), `limit` and `continue`,
      answering a `PodList` whose `metadata.resourceVersion` is the store's.
    * `GET pods?watch=true&resourceVersion=N` — a chunked NDJSON stream: replay of
      every history event after `N`, then live events, bookmarks on request. An
      `N` older than the compaction point is expired (`expire_with/2`: an ERROR
      event inside a 200, or a plain HTTP 410, both of which a real server does).
    * `POST pods` (409 on a duplicate), `DELETE pods/<name>` (404 when absent),
      `GET pods/<name>/log` (with `follow`, `sinceTime`, `timestamps`).
    * Bearer-token auth (401 otherwise).

  The test drives the cluster with `put_pod/2`, `delete_pod/2`, `compact/1`,
  `bookmark/1`, `drop_watches/2`, `push_log/3`, and observes with `requests/1`
  and `await_watchers/2`. Resource versions are integers rendered as strings.

  K5 adds what the controller core reads and writes besides pods:

    * `GET resourcequotas` (`put_quota/2` sets them);
    * `GET`/`PUT` on a `coordination.k8s.io` `Lease` (`put_lease/2` pre-creates one,
      `lease/2` reads it back). A `PUT` carrying a stale `resourceVersion` is a 409,
      like the real server; there is no `POST`, the install pre-creates the Lease.
  """

  use GenServer

  alias Arbiter.NodeAgent.K8s.Client

  @token "fake-token"

  # --- start --------------------------------------------------------------

  @doc """
  Starts the server and a Bandit listener under the test supervisor. Returns
  `%{api: pid, url: base_url, client: %Client{}}` — a client already pointed at it.
  """
  def start!(opts \\ []) do
    namespace = Keyword.get(opts, :namespace, "arb")

    api =
      ExUnit.Callbacks.start_supervised!({__MODULE__, Keyword.put(opts, :namespace, namespace)})

    bandit =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: {Arbiter.Test.FakeK8sApi.Plug, api: api},
           port: 0,
           ip: :loopback,
           startup_log: false},
          id: {:bandit, api}
        )
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    url = "http://127.0.0.1:#{port}"

    client =
      Client.new(
        base_url: url,
        namespace: namespace,
        token: Keyword.get(opts, :client_token, @token),
        req_options: Keyword.get(opts, :req_options, [])
      )

    %{api: api, url: url, client: client}
  end

  def child_spec(opts),
    do: %{id: {__MODULE__, make_ref()}, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def token, do: @token

  # --- driving the cluster --------------------------------------------------

  @doc "Adds or replaces a pod; bumps the resourceVersion; emits ADDED or MODIFIED."
  def put_pod(api, pod), do: GenServer.call(api, {:put, pod})

  @doc "Deletes a pod (as `kubectl delete` would); emits DELETED."
  def delete_pod(api, name), do: GenServer.call(api, {:delete, name})

  @doc "Forgets the event history: any resourceVersion before now is expired."
  def compact(api), do: GenServer.call(api, :compact)

  @doc "Sends a BOOKMARK carrying the current resourceVersion to every open watch."
  def bookmark(api), do: GenServer.call(api, :bookmark)

  @doc "Ends every open watch: `:close` cleanly, `:truncate` after half an event."
  def drop_watches(api, mode \\ :close), do: GenServer.call(api, {:drop, mode})

  @doc "How an expired watch is reported: `:event` (ERROR inside a 200) or `:http` (a 410)."
  def expire_with(api, mode) when mode in [:event, :http],
    do: GenServer.call(api, {:expire_with, mode})

  @doc "Makes the next `count` requests of `kind` (`:list | :watch | :create | :delete | :log | :quota | :lease_get | :lease_update`) answer `status` (an integer, or `{code, message}`)."
  def fail_next(api, kind, status, count \\ 1),
    do: GenServer.call(api, {:fail, kind, status, count})

  @doc "Sets (or replaces) a `ResourceQuota` object by `metadata.name`."
  def put_quota(api, quota), do: GenServer.call(api, {:put_quota, quota})

  @doc "Pre-creates (or replaces) a Lease; the server owns its resourceVersion."
  def put_lease(api, lease), do: GenServer.call(api, {:put_lease, lease})

  @doc "Pre-creates (or replaces) a Deployment by `metadata.name` (K9 self-upgrade)."
  def put_deployment(api, deployment), do: GenServer.call(api, {:put_deployment, deployment})

  @doc "The Deployment `name` as the server holds it, or nil."
  def deployment(api, name), do: GenServer.call(api, {:get_deployment, name})

  @doc "The Lease `name` as the server holds it, or nil."
  def lease(api, name), do: GenServer.call(api, {:get_lease, name})

  @doc """
  Sets the instant `GET /version` reports in its `Date` header (K13 clock check).
  """
  def set_clock(api, %DateTime{} = at), do: GenServer.call(api, {:set_clock, at})

  @doc """
  Makes every `POST pods` run `fun.(pod)` first; it returns `{pod, log_lines}`, the pod
  to store (a test gives it a status, as the kubelet would) and the lines its log
  holds. This is how a test plays the cluster for a pod that runs and finishes.
  """
  def on_create(api, fun) when is_function(fun, 1), do: GenServer.call(api, {:on_create, fun})

  @doc """
  Makes `POST pods` (dry run or not) refuse any pod with a `privileged` container, as
  a namespace labelled `pod-security.kubernetes.io/enforce: restricted` does.
  """
  def enforce_psa(api), do: GenServer.call(api, {:set_psa, true})

  @doc "Blocks until at least `n` watches are open."
  def await_watchers(api, n), do: GenServer.call(api, {:await_watchers, n}, 5_000)

  @doc "The requests seen so far, oldest first: `%{method, path, query, headers, body}`."
  def requests(api), do: GenServer.call(api, :requests)

  def current_rv(api), do: GenServer.call(api, :rv)

  @doc "Appends a log line to a pod's log (timestamped by the server)."
  def push_log(api, pod, text), do: GenServer.call(api, {:push_log, pod, text})

  @doc "Ends every follower of `pod`'s log."
  def finish_logs(api, pod), do: GenServer.call(api, {:finish_logs, pod})

  # --- calls from the Plug --------------------------------------------------

  @doc false
  def handle(api, request), do: GenServer.call(api, request)

  # --- server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %{
       namespace: Keyword.fetch!(opts, :namespace),
       rv: Keyword.get(opts, :rv, 100),
       pods: %{},
       history: [],
       compacted: 0,
       watchers: [],
       waiters: [],
       requests: [],
       fail: %{},
       expire_with: :event,
       logs: %{},
       quotas: %{},
       leases: %{},
       deployments: %{},
       followers: %{},
       finished: MapSet.new(),
       clock: nil,
       psa: false,
       on_create: nil
     }}
  end

  @impl true
  def handle_call({:put, pod}, _from, state) do
    name = pod["metadata"]["name"]
    type = if Map.has_key?(state.pods, name), do: :modified, else: :added
    rv = state.rv + 1
    # A pod keeps its uid across modifications; a test recreating one sets a new uid.
    held_uid = get_in(state.pods, [name, "metadata", "uid"])

    pod =
      update_in(pod, ["metadata"], fn meta ->
        meta
        |> Map.put("resourceVersion", Integer.to_string(rv))
        |> Map.put_new("uid", held_uid || "uid-#{name}-#{rv}")
      end)

    state = %{state | rv: rv, pods: Map.put(state.pods, name, pod)}
    {:reply, pod, emit(state, rv, type, pod)}
  end

  def handle_call({:delete, name}, _from, state) do
    case Map.pop(state.pods, name) do
      {nil, _} ->
        {:reply, :not_found, state}

      {pod, pods} ->
        rv = state.rv + 1
        pod = put_in(pod, ["metadata", "resourceVersion"], Integer.to_string(rv))
        {:reply, :ok, emit(%{state | rv: rv, pods: pods}, rv, :deleted, pod)}
    end
  end

  def handle_call(:compact, _from, state),
    do: {:reply, :ok, %{state | history: [], compacted: state.rv}}

  def handle_call(:bookmark, _from, state) do
    for w <- state.watchers, do: send(w.pid, {:fake_bookmark, state.rv})
    {:reply, :ok, state}
  end

  def handle_call({:drop, mode}, _from, state) do
    for w <- state.watchers, do: send(w.pid, {:fake_drop, mode})
    {:reply, :ok, %{state | watchers: []}}
  end

  def handle_call({:expire_with, mode}, _from, state),
    do: {:reply, :ok, %{state | expire_with: mode}}

  def handle_call({:fail, kind, status, count}, _from, state) do
    {:reply, :ok, %{state | fail: Map.put(state.fail, kind, {status, count})}}
  end

  def handle_call({:await_watchers, n}, from, state) do
    if length(state.watchers) >= n do
      {:reply, :ok, state}
    else
      {:noreply, %{state | waiters: [{from, n} | state.waiters]}}
    end
  end

  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}
  def handle_call(:rv, _from, state), do: {:reply, state.rv, state}
  def handle_call(:namespace, _from, state), do: {:reply, state.namespace, state}

  def handle_call({:record, request}, _from, state),
    do: {:reply, :ok, %{state | requests: [request | state.requests]}}

  def handle_call({:maybe_fail, kind}, _from, state) do
    case Map.get(state.fail, kind) do
      {status, count} when count > 0 ->
        {:reply, {:fail, status}, %{state | fail: Map.put(state.fail, kind, {status, count - 1})}}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:list, selector, limit, continue}, _from, state) do
    items =
      state.pods
      |> Map.values()
      |> Enum.filter(&matches?(&1, selector))
      |> Enum.sort_by(& &1["metadata"]["name"])

    start = if continue in [nil, ""], do: 0, else: String.to_integer(continue)
    page = items |> Enum.drop(start) |> take(limit)
    next = start + length(page)

    meta = %{"resourceVersion" => Integer.to_string(state.rv)}

    meta =
      if next < length(items), do: Map.put(meta, "continue", Integer.to_string(next)), else: meta

    {:reply, %{"kind" => "PodList", "apiVersion" => "v1", "metadata" => meta, "items" => page},
     state}
  end

  def handle_call({:get, name}, _from, state), do: {:reply, Map.get(state.pods, name), state}

  def handle_call({:set_clock, at}, _from, state), do: {:reply, :ok, %{state | clock: at}}
  def handle_call({:set_psa, on}, _from, state), do: {:reply, :ok, %{state | psa: on}}
  def handle_call(:psa, _from, state), do: {:reply, state.psa, state}
  def handle_call(:clock, _from, state), do: {:reply, state.clock, state}
  def handle_call({:on_create, fun}, _from, state), do: {:reply, :ok, %{state | on_create: fun}}

  def handle_call({:create, pod}, _from, state) do
    name = get_in(pod, ["metadata", "name"])

    if Map.has_key?(state.pods, name) do
      {:reply, {:error, 409, "AlreadyExists", "pods \"#{name}\" already exists"}, state}
    else
      {pod, lines} = if state.on_create, do: state.on_create.(pod), else: {pod, []}
      {:reply, created, state} = handle_call({:put, pod}, nil, state)

      state =
        Enum.reduce(lines, state, fn text, acc ->
          {:reply, _ts, acc} = handle_call({:push_log, name, text}, nil, acc)
          acc
        end)

      {:reply, {:ok, created}, state}
    end
  end

  def handle_call({:watch, pid, selector, from_rv}, _from, state) do
    cond do
      from_rv < state.compacted ->
        {:reply, {:expired, state.expire_with}, state}

      true ->
        replay =
          for {rv, type, pod} <- Enum.reverse(state.history),
              rv > from_rv,
              matches?(pod, selector),
              do: {type, pod}

        watchers = [%{pid: pid, selector: selector} | state.watchers]
        Process.monitor(pid)
        state = %{state | watchers: watchers}

        {ready, waiting} =
          Enum.split_with(state.waiters, fn {_from, n} -> length(watchers) >= n end)

        for {from, _} <- ready, do: GenServer.reply(from, :ok)
        {:reply, {:ok, replay}, %{state | waiters: waiting}}
    end
  end

  def handle_call({:put_quota, quota}, _from, state) do
    {:reply, :ok,
     %{state | quotas: Map.put(state.quotas, get_in(quota, ["metadata", "name"]), quota)}}
  end

  def handle_call(:quotas, _from, state) do
    {:reply, state.quotas |> Enum.sort() |> Enum.map(&elem(&1, 1)), state}
  end

  def handle_call({:put_lease, lease}, _from, state) do
    name = get_in(lease, ["metadata", "name"])
    rv = state.rv + 1
    lease = put_in(lease, ["metadata", "resourceVersion"], Integer.to_string(rv))
    {:reply, lease, %{state | rv: rv, leases: Map.put(state.leases, name, lease)}}
  end

  def handle_call({:get_lease, name}, _from, state), do: {:reply, state.leases[name], state}

  def handle_call({:put_deployment, dep}, _from, state),
    do:
      {:reply, dep,
       %{state | deployments: Map.put(state.deployments, dep["metadata"]["name"], dep)}}

  def handle_call({:get_deployment, name}, _from, state),
    do: {:reply, state.deployments[name], state}

  # A strategic merge patch, as far as the self-upgrade needs: maps merge, and the
  # `containers` list merges by `name`.
  def handle_call({:patch_deployment, name, patch}, _from, state) do
    case state.deployments[name] do
      nil ->
        {:reply, :not_found, state}

      dep ->
        merged = strategic_merge(dep, patch)
        {:reply, {:ok, merged}, %{state | deployments: Map.put(state.deployments, name, merged)}}
    end
  end

  def handle_call({:update_lease, name, lease}, _from, state) do
    case state.leases[name] do
      nil ->
        {:reply, :not_found, state}

      held ->
        if get_in(lease, ["metadata", "resourceVersion"]) ==
             get_in(held, ["metadata", "resourceVersion"]) do
          rv = state.rv + 1
          lease = put_in(lease, ["metadata", "resourceVersion"], Integer.to_string(rv))
          {:reply, {:ok, lease}, %{state | rv: rv, leases: Map.put(state.leases, name, lease)}}
        else
          {:reply, :conflict, state}
        end
    end
  end

  def handle_call({:push_log, pod, text}, _from, state) do
    n = length(Map.get(state.logs, pod, [])) + 1
    ts = "2026-10-10T12:00:00." <> String.pad_leading(Integer.to_string(n), 9, "0") <> "Z"
    for f <- Map.get(state.followers, pod, []), do: send(f, {:fake_log, ts, text})

    {:reply, ts,
     %{state | logs: Map.update(state.logs, pod, [{ts, text}], &(&1 ++ [{ts, text}]))}}
  end

  def handle_call({:finish_logs, pod}, _from, state) do
    for f <- Map.get(state.followers, pod, []), do: send(f, :fake_log_end)

    {:reply, :ok,
     %{
       state
       | followers: Map.delete(state.followers, pod),
         finished: MapSet.put(state.finished, pod)
     }}
  end

  def handle_call({:read_log, pod, follow?, pid}, _from, state) do
    if Map.has_key?(state.pods, pod) do
      lines = Map.get(state.logs, pod, [])
      follow? = follow? and not MapSet.member?(state.finished, pod)

      state =
        if follow?,
          do: %{state | followers: Map.update(state.followers, pod, [pid], &[pid | &1])},
          else: state

      {:reply, {:ok, lines, follow?}, state}
    else
      {:reply, :not_found, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state) do
    {:noreply,
     %{
       state
       | watchers: Enum.reject(state.watchers, &(&1.pid == pid)),
         followers: Map.new(state.followers, fn {k, v} -> {k, List.delete(v, pid)} end)
     }}
  end

  defp emit(state, rv, type, pod) do
    for w <- state.watchers, matches?(pod, w.selector), do: send(w.pid, {:fake_event, type, pod})
    %{state | history: [{rv, type, pod} | state.history]}
  end

  defp take(items, nil), do: items
  defp take(items, limit), do: Enum.take(items, limit)

  defp strategic_merge(%{} = base, %{} = patch) do
    Map.merge(base, patch, fn
      "containers", old, new when is_list(old) and is_list(new) -> merge_named(old, new)
      _key, old, new -> strategic_merge(old, new)
    end)
  end

  defp strategic_merge(_base, patch), do: patch

  defp merge_named(old, new) do
    Enum.map(old, fn container ->
      case Enum.find(new, &(&1["name"] == container["name"])) do
        nil -> container
        change -> strategic_merge(container, change)
      end
    end)
  end

  @doc false
  def matches?(pod, selector) do
    labels = get_in(pod, ["metadata", "labels"]) || %{}
    Enum.all?(selector, fn {k, v} -> labels[k] == v end)
  end
end

defmodule Arbiter.Test.FakeK8sApi.Plug do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  alias Arbiter.Test.FakeK8sApi

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    api = Keyword.fetch!(opts, :api)
    {:ok, body, conn} = read_body(conn)
    ns = FakeK8sApi.handle(api, :namespace)

    FakeK8sApi.handle(
      api,
      {:record,
       %{
         method: conn.method,
         path: conn.request_path,
         query: conn.query_string,
         params: Plug.Conn.fetch_query_params(conn).query_params,
         headers: Map.new(conn.req_headers),
         body: body
       }}
    )

    if get_req_header(conn, "authorization") == ["Bearer " <> FakeK8sApi.token()] do
      route(conn, api, ns, body)
    else
      status(conn, 401, "Unauthorized", "Unauthorized")
    end
  end

  # --- routes ---------------------------------------------------------------

  defp route(
         %{method: "GET", path_info: ["api", "v1", "namespaces", ns, "pods"]} = conn,
         api,
         ns,
         _body
       ) do
    conn = fetch_query_params(conn)
    params = conn.query_params
    selector = parse_selector(params["labelSelector"])

    if params["watch"] in ["true", "1"] do
      watch(conn, api, selector, params)
    else
      with :ok <- check_fail(conn, api, :list) do
        limit = params["limit"] && String.to_integer(params["limit"])
        json(conn, 200, FakeK8sApi.handle(api, {:list, selector, limit, params["continue"]}))
      end
    end
  end

  defp route(
         %{method: "POST", path_info: ["api", "v1", "namespaces", ns, "pods"]} = conn,
         api,
         ns,
         body
       ) do
    with :ok <- check_fail(conn, api, :create),
         :ok <- check_psa(conn, api, body) do
      if fetch_query_params(conn).query_params["dryRun"] == "All" do
        json(conn, 201, Jason.decode!(body))
      else
        case FakeK8sApi.handle(api, {:create, Jason.decode!(body)}) do
          {:ok, pod} -> json(conn, 201, pod)
          {:error, code, reason, message} -> status(conn, code, reason, message)
        end
      end
    end
  end

  defp route(%{method: "GET", path_info: ["version"]} = conn, api, _ns, _body) do
    conn =
      case FakeK8sApi.handle(api, :clock) do
        %DateTime{} = at ->
          put_resp_header(conn, "date", Calendar.strftime(at, "%a, %d %b %Y %H:%M:%S GMT"))

        nil ->
          conn
      end

    json(conn, 200, %{"major" => "1", "minor" => "31", "gitVersion" => "v1.31.2+fake"})
  end

  defp route(
         %{method: "GET", path_info: ["api", "v1", "namespaces", ns, "pods", name, "log"]} = conn,
         api,
         ns,
         _
       ) do
    with :ok <- check_fail(conn, api, :log), do: log(fetch_query_params(conn), api, name)
  end

  defp route(
         %{method: "GET", path_info: ["api", "v1", "namespaces", ns, "pods", name]} = conn,
         api,
         ns,
         _
       ) do
    case FakeK8sApi.handle(api, {:get, name}) do
      nil -> status(conn, 404, "NotFound", "pods \"#{name}\" not found")
      pod -> json(conn, 200, pod)
    end
  end

  defp route(
         %{method: "DELETE", path_info: ["api", "v1", "namespaces", ns, "pods", name]} = conn,
         api,
         ns,
         _
       ) do
    with :ok <- check_fail(conn, api, :delete) do
      case FakeK8sApi.handle(api, {:delete, name}) do
        :ok -> json(conn, 200, %{"kind" => "Status", "status" => "Success"})
        :not_found -> status(conn, 404, "NotFound", "pods \"#{name}\" not found")
      end
    end
  end

  defp route(
         %{method: "GET", path_info: ["api", "v1", "namespaces", ns, "resourcequotas"]} = conn,
         api,
         ns,
         _body
       ) do
    with :ok <- check_fail(conn, api, :quota) do
      json(conn, 200, %{
        "kind" => "ResourceQuotaList",
        "apiVersion" => "v1",
        "metadata" => %{},
        "items" => FakeK8sApi.handle(api, :quotas)
      })
    end
  end

  defp route(
         %{
           method: "GET",
           path_info: ["apis", "coordination.k8s.io", "v1", "namespaces", ns, "leases", name]
         } = conn,
         api,
         ns,
         _body
       ) do
    with :ok <- check_fail(conn, api, :lease_get) do
      case FakeK8sApi.handle(api, {:get_lease, name}) do
        nil -> status(conn, 404, "NotFound", "leases \"#{name}\" not found")
        lease -> json(conn, 200, lease)
      end
    end
  end

  defp route(
         %{
           method: "PUT",
           path_info: ["apis", "coordination.k8s.io", "v1", "namespaces", ns, "leases", name]
         } = conn,
         api,
         ns,
         body
       ) do
    with :ok <- check_fail(conn, api, :lease_update) do
      case FakeK8sApi.handle(api, {:update_lease, name, Jason.decode!(body)}) do
        {:ok, lease} -> json(conn, 200, lease)
        :conflict -> status(conn, 409, "Conflict", "the object has been modified")
        :not_found -> status(conn, 404, "NotFound", "leases \"#{name}\" not found")
      end
    end
  end

  defp route(
         %{
           method: "GET",
           path_info: ["apis", "apps", "v1", "namespaces", ns, "deployments", name]
         } = conn,
         api,
         ns,
         _body
       ) do
    with :ok <- check_fail(conn, api, :deployment_get) do
      case FakeK8sApi.handle(api, {:get_deployment, name}) do
        nil -> status(conn, 404, "NotFound", "deployments.apps \"#{name}\" not found")
        deployment -> json(conn, 200, deployment)
      end
    end
  end

  defp route(
         %{
           method: "PATCH",
           path_info: ["apis", "apps", "v1", "namespaces", ns, "deployments", name]
         } = conn,
         api,
         ns,
         body
       ) do
    with :ok <- check_fail(conn, api, :deployment_patch) do
      if get_req_header(conn, "content-type") == ["application/strategic-merge-patch+json"] do
        case FakeK8sApi.handle(api, {:patch_deployment, name, Jason.decode!(body)}) do
          {:ok, deployment} -> json(conn, 200, deployment)
          :not_found -> status(conn, 404, "NotFound", "deployments.apps \"#{name}\" not found")
        end
      else
        status(
          conn,
          415,
          "UnsupportedMediaType",
          "the body of the request was in an unknown format"
        )
      end
    end
  end

  defp route(conn, _api, _ns, _body), do: status(conn, 404, "NotFound", "no route")

  # --- watch ----------------------------------------------------------------

  defp watch(conn, api, selector, params) do
    from_rv = String.to_integer(params["resourceVersion"] || "0")

    with :ok <- check_fail(conn, api, :watch) do
      case FakeK8sApi.handle(api, {:watch, self(), selector, from_rv}) do
        {:expired, :http} ->
          status(conn, 410, "Expired", "too old resource version: #{from_rv}")

        {:expired, :event} ->
          conn = send_chunked(conn, 200)

          event = %{
            "kind" => "Status",
            "code" => 410,
            "reason" => "Expired",
            "message" => "too old resource version"
          }

          {:ok, conn} = chunk(conn, line("ERROR", event))
          conn

        {:ok, replay} ->
          conn = send_chunked(conn, 200)
          timeout = String.to_integer(params["timeoutSeconds"] || "30") * 1000

          case send_all(conn, replay) do
            {:ok, conn} -> watch_loop(conn, timeout)
            {:error, conn} -> conn
          end
      end
    end
  end

  defp watch_loop(conn, timeout) do
    receive do
      {:fake_event, type, pod} ->
        continue(conn, line(type |> Atom.to_string() |> String.upcase(), pod), timeout)

      {:fake_bookmark, rv} ->
        continue(conn, line("BOOKMARK", bookmark(rv)), timeout)

      {:fake_drop, :close} ->
        conn

      # The handler traps exits: a server shutdown arrives as a message.
      {:EXIT, _from, _reason} ->
        conn

      {:fake_drop, :truncate} ->
        elem(chunk(conn, ~s({"type":"MODIFIED","obj)), 1)
    after
      timeout -> conn
    end
  end

  defp continue(conn, data, timeout) do
    case chunk(conn, data) do
      {:ok, conn} -> watch_loop(conn, timeout)
      {:error, _} -> conn
    end
  end

  defp send_all(conn, events) do
    Enum.reduce_while(events, {:ok, conn}, fn {type, pod}, {:ok, conn} ->
      case chunk(conn, line(type |> Atom.to_string() |> String.upcase(), pod)) do
        {:ok, conn} -> {:cont, {:ok, conn}}
        {:error, _} -> {:halt, {:error, conn}}
      end
    end)
  end

  defp bookmark(rv),
    do: %{
      "kind" => "Pod",
      "apiVersion" => "v1",
      "metadata" => %{"resourceVersion" => Integer.to_string(rv)}
    }

  defp line(type, object), do: Jason.encode!(%{"type" => type, "object" => object}) <> "\n"

  # --- logs -----------------------------------------------------------------

  defp log(conn, api, name) do
    params = conn.query_params
    follow? = params["follow"] in ["true", "1"]
    timestamps? = params["timestamps"] in ["true", "1"]
    since = params["sinceTime"]

    case FakeK8sApi.handle(api, {:read_log, name, follow?, self()}) do
      :not_found ->
        status(conn, 404, "NotFound", "pods \"#{name}\" not found")

      {:ok, lines, follow?} ->
        lines = if since, do: Enum.filter(lines, fn {ts, _} -> ts >= since end), else: lines
        conn = conn |> put_resp_content_type("text/plain") |> send_chunked(200)
        render = fn ts, text -> if(timestamps?, do: ts <> " ", else: "") <> text <> "\n" end

        {:ok, conn} =
          chunk(conn, Enum.map_join(lines, "", fn {ts, text} -> render.(ts, text) end))

        if follow?, do: log_loop(conn, render), else: conn
    end
  end

  defp log_loop(conn, render) do
    receive do
      {:fake_log, ts, text} ->
        case chunk(conn, render.(ts, text)) do
          {:ok, conn} -> log_loop(conn, render)
          {:error, _} -> conn
        end

      :fake_log_end ->
        conn

      {:EXIT, _from, _reason} ->
        conn
    after
      30_000 -> conn
    end
  end

  # --- plumbing -------------------------------------------------------------

  defp check_fail(conn, api, kind) do
    case FakeK8sApi.handle(api, {:maybe_fail, kind}) do
      :ok -> :ok
      {:fail, {code, message}} -> status(conn, code, "InjectedFailure", message)
      {:fail, code} -> status(conn, code, "InjectedFailure", "injected #{code}")
    end
  end

  defp check_psa(conn, api, body) do
    pod = Jason.decode!(body)

    containers =
      (get_in(pod, ["spec", "containers"]) || []) ++
        (get_in(pod, ["spec", "initContainers"]) || [])

    if FakeK8sApi.handle(api, :psa) and
         Enum.any?(containers, &(get_in(&1, ["securityContext", "privileged"]) == true)) do
      status(
        conn,
        403,
        "Forbidden",
        ~s(pods "#{get_in(pod, ["metadata", "name"])}" is forbidden: violates PodSecurity "restricted:latest": privileged)
      )
    else
      :ok
    end
  end

  defp parse_selector(nil), do: %{}
  defp parse_selector(""), do: %{}

  defp parse_selector(text) do
    text
    |> String.split(",", trim: true)
    |> Map.new(fn pair -> pair |> String.split("=", parts: 2) |> List.to_tuple() end)
  end

  defp json(conn, code, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(code, Jason.encode!(body))
  end

  defp status(conn, code, reason, message) do
    json(conn, code, %{
      "kind" => "Status",
      "apiVersion" => "v1",
      "status" => "Failure",
      "code" => code,
      "reason" => reason,
      "message" => message
    })
  end
end
