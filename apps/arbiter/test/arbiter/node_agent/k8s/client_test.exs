defmodule Arbiter.NodeAgent.K8s.ClientTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.Client
  alias Arbiter.Test.FakeK8sApi

  @labels %{"arbiter.dev/install" => "inst-1", "arbiter.dev/node" => "node-1"}

  defp pod(name, labels \\ @labels),
    do: %{"metadata" => %{"name" => name, "labels" => labels}, "spec" => %{}}

  setup do
    {:ok, FakeK8sApi.start!()}
  end

  describe "in_cluster/1" do
    @describetag :tmp_dir

    defp write_sa(dir, token \\ "sa-token-1\n") do
      File.write!(Path.join(dir, "token"), token)
      File.write!(Path.join(dir, "namespace"), "arbiter-workers\n")

      File.write!(
        Path.join(dir, "ca.crt"),
        "-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n"
      )

      dir
    end

    test "builds the client from the service-account files and the KUBERNETES_SERVICE_* env", %{
      tmp_dir: dir
    } do
      env = %{"KUBERNETES_SERVICE_HOST" => "10.96.0.1", "KUBERNETES_SERVICE_PORT" => "443"}
      assert {:ok, client} = Client.in_cluster(sa_dir: write_sa(dir), env: env)

      assert client.base_url == "https://10.96.0.1:443"
      assert client.namespace == "arbiter-workers"
      assert {:file, Path.join(dir, "token")} == client.token

      assert client.req_options[:connect_options][:transport_opts][:cacertfile] ==
               Path.join(dir, "ca.crt")
    end

    test "brackets an IPv6 service host", %{tmp_dir: dir} do
      env = %{"KUBERNETES_SERVICE_HOST" => "fd00::1", "KUBERNETES_SERVICE_PORT_HTTPS" => "6443"}
      assert {:ok, client} = Client.in_cluster(sa_dir: write_sa(dir), env: env)
      assert client.base_url == "https://[fd00::1]:6443"
    end

    test "outside a cluster it says so", %{tmp_dir: dir} do
      assert {:error, :not_in_cluster} = Client.in_cluster(sa_dir: write_sa(dir), env: %{})
    end

    test "a missing token file is an error, not a crash", %{tmp_dir: dir} do
      env = %{"KUBERNETES_SERVICE_HOST" => "10.96.0.1"}

      assert {:error, {:service_account, "token", :enoent}} =
               Client.in_cluster(sa_dir: dir, env: env)
    end

    test "the token is re-read on every request (projected tokens rotate)", %{
      tmp_dir: dir,
      url: url
    } do
      sa = write_sa(dir, FakeK8sApi.token() <> "\n")
      env = %{"KUBERNETES_SERVICE_HOST" => "127.0.0.1"}
      {:ok, client} = Client.in_cluster(sa_dir: sa, env: env)
      client = %{client | base_url: url, namespace: "arb", req_options: []}

      assert {:ok, _} = Client.list_pods(client)
      File.write!(Path.join(dir, "token"), "rotated-and-wrong")
      assert {:error, :unauthorized} = Client.list_pods(client)
      File.write!(Path.join(dir, "token"), FakeK8sApi.token())
      assert {:ok, _} = Client.list_pods(client)
    end
  end

  describe "auth" do
    test "every request carries the bearer token", %{client: client, api: api} do
      {:ok, _} = Client.list_pods(client)
      assert [%{headers: %{"authorization" => "Bearer " <> token}}] = FakeK8sApi.requests(api)
      assert token == FakeK8sApi.token()
    end

    test "a bad token is :unauthorized", %{client: client} do
      assert {:error, :unauthorized} = Client.list_pods(%{client | token: "nope"})
    end
  end

  describe "list_pods/2" do
    test "returns the items and the list's resourceVersion", %{client: client, api: api} do
      FakeK8sApi.put_pod(api, pod("a"))
      FakeK8sApi.put_pod(api, pod("b"))

      assert {:ok, %{items: items, resource_version: rv}} = Client.list_pods(client)
      assert Enum.map(items, & &1["metadata"]["name"]) == ["a", "b"]
      assert rv == Integer.to_string(FakeK8sApi.current_rv(api))
    end

    test "sends the label selector and filters by it", %{client: client, api: api} do
      FakeK8sApi.put_pod(api, pod("mine"))
      FakeK8sApi.put_pod(api, pod("other", %{"arbiter.dev/install" => "someone-else"}))

      assert {:ok, %{items: [%{"metadata" => %{"name" => "mine"}}]}} =
               Client.list_pods(client, label_selector: Client.label_selector(@labels))

      [%{params: params}] = FakeK8sApi.requests(api)
      assert params["labelSelector"] == "arbiter.dev/install=inst-1,arbiter.dev/node=node-1"
    end

    test "follows continue tokens across pages", %{client: client, api: api} do
      for n <- 1..5, do: FakeK8sApi.put_pod(api, pod("p#{n}"))

      assert {:ok, %{items: items}} = Client.list_pods(client, limit: 2)
      assert Enum.map(items, & &1["metadata"]["name"]) == ~w(p1 p2 p3 p4 p5)
      assert length(FakeK8sApi.requests(api)) == 3
    end

    test "a server error is reported with its status", %{client: client, api: api} do
      FakeK8sApi.fail_next(api, :list, 500)
      assert {:error, {:http, 500, "injected 500"}} = Client.list_pods(client)
    end

    test "an unreachable server is a transport error", %{client: client} do
      assert {:error, {:transport, _}} =
               Client.list_pods(%{client | base_url: "http://127.0.0.1:1"})
    end
  end

  describe "create_pod/2" do
    test "POSTs the manifest and returns the stored pod", %{client: client, api: api} do
      assert {:ok, %{"metadata" => %{"name" => "arb-1", "resourceVersion" => _}}} =
               Client.create_pod(client, pod("arb-1"))

      assert [%{method: "POST", body: body}] = FakeK8sApi.requests(api)
      assert Jason.decode!(body)["metadata"]["name"] == "arb-1"
    end

    test "a duplicate name is :already_exists", %{client: client} do
      {:ok, _} = Client.create_pod(client, pod("dup"))
      assert {:error, :already_exists} = Client.create_pod(client, pod("dup"))
    end

    test "a forbidden create (admission, RBAC) carries the server's message", %{
      client: client,
      api: api
    } do
      FakeK8sApi.fail_next(api, :create, 403)
      assert {:error, {:forbidden, "injected 403"}} = Client.create_pod(client, pod("x"))
    end
  end

  describe "create_pod/3 with dry_run" do
    test "sends dryRun=All and stores nothing", %{client: client, api: api} do
      assert {:ok, %{"metadata" => %{"name" => "dry-1"}}} =
               Client.create_pod(client, pod("dry-1"), dry_run: true)

      assert %{params: %{"dryRun" => "All"}} =
               api |> FakeK8sApi.requests() |> Enum.find(&(&1.method == "POST"))

      assert {:ok, %{items: []}} = Client.list_pods(client)
    end

    test "a rejection comes back as the server's message", %{client: client, api: api} do
      FakeK8sApi.fail_next(api, :create, {403, "violates PodSecurity \"restricted:latest\""})

      assert {:error, {:forbidden, "violates PodSecurity" <> _}} =
               Client.create_pod(client, pod("dry-2"), dry_run: true)
    end
  end

  describe "get_pod/2 and server_time/1" do
    test "get_pod reads one pod; a missing one is :not_found", %{client: client, api: api} do
      FakeK8sApi.put_pod(api, pod("here"))
      assert {:ok, %{"metadata" => %{"name" => "here"}}} = Client.get_pod(client, "here")
      assert {:error, :not_found} = Client.get_pod(client, "gone")
    end

    test "server_time reads the API server's Date header", %{client: client, api: api} do
      FakeK8sApi.set_clock(api, ~U[2026-10-10 12:00:00Z])
      assert {:ok, ~U[2026-10-10 12:00:00Z]} = Client.server_time(client)
    end

    test "server_time without a Date header is an error" do
      client =
        Client.new(
          base_url: "http://k8s.test",
          namespace: "arb",
          req_options: [plug: fn conn -> Plug.Conn.send_resp(conn, 200, "{}") end]
        )

      assert {:error, :no_date_header} = Client.server_time(client)
    end
  end

  describe "delete_pod/3" do
    test "sends the grace period and reports :deleted", %{client: client, api: api} do
      FakeK8sApi.put_pod(api, pod("gone"))
      assert {:ok, :deleted} = Client.delete_pod(client, "gone", grace_period_seconds: 120)

      assert [%{method: "DELETE", body: body}] = FakeK8sApi.requests(api)

      assert %{"gracePeriodSeconds" => 120, "propagationPolicy" => "Background"} =
               Jason.decode!(body)
    end

    test "grace 0 is sent as 0, not omitted", %{client: client, api: api} do
      FakeK8sApi.put_pod(api, pod("now"))
      {:ok, :deleted} = Client.delete_pod(client, "now", grace_period_seconds: 0)
      assert %{"gracePeriodSeconds" => 0} = Jason.decode!(hd(FakeK8sApi.requests(api)).body)
    end

    test "a uid precondition is sent", %{client: client, api: api} do
      FakeK8sApi.put_pod(api, pod("p"))
      {:ok, :deleted} = Client.delete_pod(client, "p", uid: "u-1")

      assert %{"preconditions" => %{"uid" => "u-1"}} =
               Jason.decode!(hd(FakeK8sApi.requests(api)).body)
    end

    test "deleting a pod that is already gone is :not_found, not an error", %{client: client} do
      assert {:ok, :not_found} = Client.delete_pod(client, "never-was")
    end
  end

  describe "logs" do
    test "read_log/3 returns the text of a non-follow read", %{client: client, api: api} do
      FakeK8sApi.put_pod(api, pod("l"))
      FakeK8sApi.push_log(api, "l", "one")
      FakeK8sApi.push_log(api, "l", "two")

      assert {:ok, text} = Client.read_log(client, "l", container: "worker", timestamps: true)
      assert [<<_ts::binary-size(30)>> <> " one", _] = String.split(text, "\n", trim: true)

      [%{params: params}] = FakeK8sApi.requests(api)
      assert %{"container" => "worker", "timestamps" => "true"} = params
    end

    test "follow_log/5 streams chunks until the server ends the log, then returns the accumulator",
         %{client: client, api: api} do
      FakeK8sApi.put_pod(api, pod("f"))
      FakeK8sApi.push_log(api, "f", "before")

      task =
        Task.async(fn ->
          Client.follow_log(client, "f", [], fn chunk, acc -> {:cont, [chunk | acc]} end,
            container: "worker",
            timestamps: true
          )
        end)

      FakeK8sApi.push_log(api, "f", "after")
      FakeK8sApi.finish_logs(api, "f")

      assert {:closed, chunks} = Task.await(task)
      text = chunks |> Enum.reverse() |> IO.iodata_to_binary()
      assert text =~ "before\n"
      assert text =~ "after\n"
    end

    test "follow_log/5 on a missing pod is :not_found", %{client: client} do
      assert {{:error, :not_found}, []} =
               Client.follow_log(client, "ghost", [], fn c, a -> {:cont, [c | a]} end)
    end

    test "sinceTime is sent as given", %{client: client, api: api} do
      FakeK8sApi.put_pod(api, pod("s"))
      {:ok, _} = Client.read_log(client, "s", since_time: "2026-10-10T12:00:00.000000003Z")
      [%{params: params}] = FakeK8sApi.requests(api)
      assert params["sinceTime"] == "2026-10-10T12:00:00.000000003Z"
    end
  end

  describe "watch_pods/5" do
    test "replays events after the resourceVersion and ends {:closed, acc} when the server closes",
         %{client: client, api: api} do
      FakeK8sApi.put_pod(api, pod("a"))
      rv = Integer.to_string(FakeK8sApi.current_rv(api))
      FakeK8sApi.put_pod(api, pod("b"))
      FakeK8sApi.delete_pod(api, "a")

      task =
        Task.async(fn ->
          Client.watch_pods(client, rv, [], fn ev, acc -> {:cont, [ev | acc]} end)
        end)

      FakeK8sApi.await_watchers(api, 1)
      FakeK8sApi.drop_watches(api)

      assert {:closed, events} = Task.await(task)

      assert [
               {:added, %{"metadata" => %{"name" => "b"}}},
               {:deleted, %{"metadata" => %{"name" => "a"}}}
             ] = Enum.reverse(events)
    end

    test "asks for bookmarks, the resourceVersion and the selector", %{client: client, api: api} do
      task =
        Task.async(fn ->
          Client.watch_pods(client, "100", :ok, fn _, acc -> {:cont, acc} end,
            label_selector: "a=b",
            timeout_s: 7
          )
        end)

      FakeK8sApi.await_watchers(api, 1)
      FakeK8sApi.drop_watches(api)
      Task.await(task)

      [%{params: params}] = FakeK8sApi.requests(api)

      assert %{
               "watch" => "true",
               "resourceVersion" => "100",
               "allowWatchBookmarks" => "true",
               "labelSelector" => "a=b",
               "timeoutSeconds" => "7"
             } = params
    end

    test "delivers live events and bookmarks as they arrive", %{client: client, api: api} do
      parent = self()

      task =
        Task.async(fn ->
          Client.watch_pods(client, "100", 0, fn ev, n ->
            send(parent, {:ev, ev})
            {:cont, n + 1}
          end)
        end)

      FakeK8sApi.await_watchers(api, 1)
      FakeK8sApi.put_pod(api, pod("live"))
      assert_receive {:ev, {:added, %{"metadata" => %{"name" => "live"}}}}, 5_000
      FakeK8sApi.bookmark(api)
      assert_receive {:ev, {:bookmark, %{"metadata" => %{"resourceVersion" => _}}}}, 5_000
      FakeK8sApi.drop_watches(api)
      assert {:closed, 2} = Task.await(task)
    end

    test "the handler can halt the watch", %{client: client, api: api} do
      task =
        Task.async(fn -> Client.watch_pods(client, "100", 0, fn _ev, n -> {:halt, n + 1} end) end)

      FakeK8sApi.await_watchers(api, 1)
      FakeK8sApi.put_pod(api, pod("one"))
      assert {:halted, 1} = Task.await(task)
    end

    test "an expired resourceVersion (ERROR event in a 200) is :gone", %{client: client, api: api} do
      FakeK8sApi.put_pod(api, pod("a"))
      FakeK8sApi.compact(api)
      assert {:gone, :acc} = Client.watch_pods(client, "100", :acc, fn _, acc -> {:cont, acc} end)
    end

    test "an expired resourceVersion (HTTP 410) is :gone", %{client: client, api: api} do
      FakeK8sApi.expire_with(api, :http)
      FakeK8sApi.put_pod(api, pod("a"))
      FakeK8sApi.compact(api)
      assert {:gone, :acc} = Client.watch_pods(client, "100", :acc, fn _, acc -> {:cont, acc} end)
    end

    test "a non-200 reply is an error carrying the status, and the handler never sees it", %{
      client: client,
      api: api
    } do
      FakeK8sApi.fail_next(api, :watch, 503)

      assert {{:error, {:http, 503, "injected 503"}}, :acc} =
               Client.watch_pods(client, "100", :acc, fn _, _ -> flunk("handler called") end)
    end

    test "a connection that dies mid-event drops the partial event", %{client: client, api: api} do
      task =
        Task.async(fn ->
          Client.watch_pods(client, "100", [], fn ev, acc -> {:cont, [ev | acc]} end)
        end)

      FakeK8sApi.await_watchers(api, 1)
      FakeK8sApi.drop_watches(api, :truncate)
      assert {:closed, []} = Task.await(task)
    end
  end
end
