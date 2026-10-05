defmodule ArbiterWeb.WorkerBridgeIdentityTest do
  @moduledoc """
  bd-c1qq7l (G9): what the endpoint makes of a request that arrives through a
  jailed worker's Arbiter bridge (`<run>.arb.sock`), driven end to end.

  A real `Arbiter.Worker.Egress` run is started with `JailRun.start/1`, its
  `arb` bridge socket is opened with a raw HTTP/1.1 client, and the bridge
  dials the real endpoint over a real Bandit listener. That is the only way to
  prove the part the design rests on: the endpoint's `peer_data` for the
  bridge's connection is the very `{address, port}` the bridge registered.
  """
  # async: false — Bandit's request processes share the sandbox connection.
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.Egress
  alias Arbiter.Worker.Egress.JailRun
  alias ArbiterWeb.SessionSocket

  require Phoenix.ChannelTest
  @endpoint ArbiterWeb.Endpoint

  setup do
    listener =
      start_supervised!(
        {Bandit, plug: ArbiterWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    dir =
      Path.join(Arbiter.Config.Paths.scratch_root(), "g9#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    mine = workspace!("g9a")
    other = workspace!("g9b")

    %{
      port: port,
      dir: dir,
      ws: mine,
      other_ws: other,
      task: task!(mine, "my task"),
      sibling: task!(mine, "sibling task"),
      foreign: task!(other, "foreign task")
    }
  end

  defp workspace!(prefix) do
    n = System.unique_integer([:positive])

    Ash.create!(Workspace, %{name: "#{prefix}-#{n}", prefix: "#{prefix}#{n}", config: %{}})
  end

  defp task!(ws, title), do: Ash.create!(Issue, %{title: title, workspace_id: ws.id})

  # A jailed run for `task`, its bridge pointed at the Bandit listener on `port`.
  defp bridge!(task, ctx, opts \\ []) do
    owner = start_supervised!({Agent, fn -> :ok end}, id: make_ref())
    token = Keyword.get(opts, :token, Scope.mint_worker(task))

    {:ok, _network, run_id} =
      JailRun.start(
        owner: owner,
        dir: ctx.dir,
        arbiter_url: "http://127.0.0.1:#{ctx.port}/mcp",
        arb_token: token
      )

    on_exit(fn -> Egress.stop_run(run_id) end)
    %{path: Egress.bridge_path(run_id, "arb", ctx.dir), run_id: run_id, owner: owner}
  end

  # One request over `path` (a unix socket), `Connection: close`, read to EOF.
  defp http(path, method, url, opts \\ []) do
    body = if json = opts[:json], do: Jason.encode!(json), else: ""

    headers =
      [{"host", "127.0.0.1"}, {"connection", "close"}] ++
        if(json, do: [{"content-type", "application/json"}], else: []) ++
        Keyword.get(opts, :headers, [])

    head =
      Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end) <>
        "content-length: #{byte_size(body)}\r\n"

    {:ok, sock} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.send(sock, "#{method} #{url} HTTP/1.1\r\n#{head}\r\n#{body}")
    raw = recv_all(sock, "")
    :gen_tcp.close(sock)
    parse(raw)
  end

  defp recv_all(sock, acc) do
    case :gen_tcp.recv(sock, 0, 10_000) do
      {:ok, data} -> recv_all(sock, acc <> data)
      {:error, _} -> acc
    end
  end

  defp parse(""), do: %{status: nil, body: nil}

  defp parse(raw) do
    [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
    "HTTP/1.1 " <> rest = head
    {status, _} = Integer.parse(rest)
    %{status: status, body: decode(body)}
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  defp direct(port, method, url, opts \\ []) do
    resp =
      Req.request!([method: method, url: "http://127.0.0.1:#{port}#{url}", retry: false] ++ opts)

    %{status: resp.status, body: resp.body}
  end

  defp tool(path, name, arguments, headers \\ []) do
    http(path, "POST", "/mcp",
      headers: headers,
      json: %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      }
    )
  end

  defp bearer(token), do: [{"authorization", "Bearer #{token}"}]

  defp tool_failed?(%{status: 200, body: %{"error" => _}}), do: true
  defp tool_failed?(%{status: 200, body: %{"result" => %{"isError" => true}}}), do: true
  defp tool_failed?(%{status: status}), do: status in [401, 403]

  describe "REST through the bridge is the worker's own scope" do
    test "no Authorization header still reads and progresses its own task", ctx do
      bridge = bridge!(ctx.task, ctx)

      assert %{status: 200, body: %{"id" => id}} =
               http(bridge.path, "GET", "/api/issues/#{ctx.task.id}")

      assert id == ctx.task.id

      assert %{status: 200} =
               http(bridge.path, "PATCH", "/api/issues/#{ctx.task.id}",
                 json: %{"notes" => "from inside the jail"}
               )
    end

    test "the same anonymous request off the bridge is not authenticated", ctx do
      assert %{status: 401} = direct(ctx.port, :get, "/api/issues/#{ctx.task.id}")
    end

    test "a coordinator token presented through the bridge is ignored", ctx do
      bridge = bridge!(ctx.task, ctx)
      coordinator = Scope.mint_coordinator(nil)

      # A coordinator could list every task; the worker scope cannot.
      assert %{status: 200} =
               direct(ctx.port, :get, "/api/issues", auth: {:bearer, coordinator})

      assert %{status: 403} =
               http(bridge.path, "GET", "/api/issues", headers: bearer(coordinator))
    end

    test "a different task's resources are refused under the worker's scope", ctx do
      bridge = bridge!(ctx.task, ctx)

      # Same workspace, other task: readable, but not writable.
      assert %{status: 403} =
               http(bridge.path, "PATCH", "/api/issues/#{ctx.sibling.id}",
                 json: %{"notes" => "not mine"}
               )

      # Another workspace: not even readable.
      assert %{status: 403} = http(bridge.path, "GET", "/api/issues/#{ctx.foreign.id}")

      assert %{status: 403} =
               http(bridge.path, "PATCH", "/api/issues/#{ctx.foreign.id}",
                 json: %{"notes" => "not mine"}
               )

      assert %{status: 403} =
               http(bridge.path, "POST", "/api/issues/#{ctx.foreign.id}/close", json: %{})
    end

    test "a run without a usable token is refused, never anonymous", ctx do
      none = bridge!(ctx.task, ctx, token: nil)
      assert %{status: 401} = http(none.path, "GET", "/api/issues/#{ctx.task.id}")

      assert %{status: 401} =
               http(none.path, "GET", "/api/issues/#{ctx.task.id}",
                 headers: bearer(Scope.mint_coordinator(nil))
               )

      coordinator = bridge!(ctx.task, ctx, token: Scope.mint_coordinator(nil))
      assert %{status: 401} = http(coordinator.path, "GET", "/api/issues/#{ctx.task.id}")

      expired = bridge!(ctx.task, ctx, token: Scope.mint_worker(ctx.task, nil, max_age: -1))
      assert %{status: 401} = http(expired.path, "GET", "/api/issues/#{ctx.task.id}")
    end

    test "only /api and /mcp are reachable through it", ctx do
      bridge = bridge!(ctx.task, ctx)

      for path <- ["/", "/events", "/proxy/v1/messages"] do
        assert %{status: 403} = http(bridge.path, "GET", path), path
      end

      assert %{status: 200} = http(bridge.path, "GET", "/api/version")
    end
  end

  describe "token minting" do
    test "POST /api/mcp/tokens is refused through the bridge, with or without a token", ctx do
      bridge = bridge!(ctx.task, ctx)

      assert %{status: 403, body: %{"error" => %{"message" => message}}} =
               http(bridge.path, "POST", "/api/mcp/tokens", json: %{})

      assert message =~ "bridge"

      assert %{status: 403} =
               http(bridge.path, "POST", "/api/mcp/tokens",
                 json: %{"ttl" => 60},
                 headers: bearer(Scope.mint_coordinator(nil))
               )

      # Even if the run's own scope were a coordinator's, the connection decides.
      assert %{status: 401} =
               http(
                 bridge!(ctx.task, ctx, token: Scope.mint_coordinator(nil)).path,
                 "POST",
                 "/api/mcp/tokens",
                 json: %{}
               )
    end

    test "off the bridge a coordinator still mints, unchanged", ctx do
      assert %{status: 200, body: %{"token" => token}} =
               direct(ctx.port, :post, "/api/mcp/tokens",
                 json: %{},
                 auth: {:bearer, Scope.mint_coordinator(nil)}
               )

      assert {:ok, %Scope{tier: :coordinator}} = Scope.from_token(token)
      assert %{status: 401} = direct(ctx.port, :post, "/api/mcp/tokens", json: %{})
    end
  end

  describe "MCP through the bridge" do
    test "no token still acts as the worker, on its own task", ctx do
      bridge = bridge!(ctx.task, ctx)

      assert %{status: 200, body: %{"result" => result}} =
               tool(bridge.path, "ticket_show", %{"id" => ctx.task.id})

      refute result["isError"]
    end

    test "off the bridge the same request has no scope", ctx do
      resp =
        direct(ctx.port, :post, "/mcp",
          json: %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "tools/call",
            "params" => %{"name" => "ticket_show", "arguments" => %{"id" => ctx.task.id}}
          }
        )

      assert resp.status == 401
    end

    test "another task's or workspace's tickets, and coordinator tools, are refused", ctx do
      bridge = bridge!(ctx.task, ctx)

      assert tool_failed?(
               tool(bridge.path, "ticket_update_progress", %{
                 "id" => ctx.sibling.id,
                 "notes" => "not mine"
               })
             )

      assert tool_failed?(tool(bridge.path, "ticket_show", %{"id" => ctx.foreign.id}))

      coordinator = Scope.mint_coordinator(nil)

      assert tool_failed?(
               tool(
                 bridge.path,
                 "ticket_update_progress",
                 %{"id" => ctx.sibling.id, "notes" => "as coordinator"},
                 bearer(coordinator)
               )
             )

      assert tool_failed?(tool(bridge.path, "worker_dispatch", %{"id" => ctx.sibling.id}))
    end

    test "a run without a usable token is refused", ctx do
      none = bridge!(ctx.task, ctx, token: nil)

      assert %{status: 401} = tool(none.path, "ticket_show", %{"id" => ctx.task.id})

      assert %{status: 401} =
               tool(
                 none.path,
                 "ticket_show",
                 %{"id" => ctx.task.id},
                 bearer(Scope.mint_coordinator(nil))
               )
    end
  end

  describe "the session socket" do
    test "refuses a bridged peer even though its address is loopback", ctx do
      bridge = bridge!(ctx.task, ctx)

      # A keep-alive request over the bridge: once it is answered the bridge's
      # connection is registered, and it stays registered while `sock` is open.
      {:ok, sock} = :gen_tcp.connect({:local, bridge.path}, 0, [:binary, active: false])
      on_exit(fn -> :gen_tcp.close(sock) end)
      :ok = :gen_tcp.send(sock, "GET /api/version HTTP/1.1\r\nhost: x\r\n\r\n")
      assert {:ok, "HTTP/1.1 200" <> _} = :gen_tcp.recv(sock, 0, 10_000)

      assert [{address, port}] = bridged_peers(bridge.run_id)
      info = %{peer_data: %{address: address, port: port, ssl_cert: nil}}
      assert :error = Phoenix.ChannelTest.connect(SessionSocket, %{}, connect_info: info)

      plain = %{
        peer_data: %{address: {127, 0, 0, 1}, port: 1, ssl_cert: nil},
        session: ArbiterWeb.DashboardAuth.Default.grant_session("token", "operator")
      }
      assert {:ok, _} = Phoenix.ChannelTest.connect(SessionSocket, %{}, connect_info: plain)
    end
  end

  # The `{address, port}` of every live connection registered for `run_id`.
  defp bridged_peers(run_id) do
    :ets.select(Arbiter.Worker.Egress.BridgeIdentity, [
      {{{:conn, :"$1", :"$2"}, run_id, :_}, [], [{{:"$1", :"$2"}}]}
    ])
  end
end
