defmodule Arbiter.NodeAgent.PodChannel.PodServerTest do
  @moduledoc """
  The pod channel's HTTPS listener, `:9444` (`docs/design/remote-workers.md` §16
  K§9.3, K§10): `/boot` (server-authenticated, the single-use nonce in the body)
  and, behind a `control` client certificate, `/seed.bundle`, `/checkpoint`,
  `/transcripts` and `/commands`. The run is always the certificate's `CN`, never
  anything the request says, so a pod can only ever act on its own run. The
  primary is a plain HTTP stand-in that records what the controller forwards
  with the node credential.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Arbiter.NodeAgent.Config
  alias Arbiter.NodeAgent.PodChannel.{PodServer, Runs}
  alias Arbiter.NodeAgent.PodChannelKit, as: Kit

  @loopback {127, 0, 0, 1}
  @credential "arbn_test_credential"

  defmodule Primary do
    @moduledoc false
    # The primary's `/nodes/runs/:run/...` surface, recording what it was sent.
    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      test = Keyword.fetch!(opts, :test)
      auth = get_req_header(conn, "authorization")

      if auth != ["Bearer " <> Keyword.fetch!(opts, :credential)] do
        send_resp(conn, 401, ~s({"error":"unauthorized"}))
      else
        route(conn, test)
      end
    end

    defp route(
           %{method: "GET", path_info: ["nodes", "runs", "veto-run", "seed.bundle"]} = conn,
           _test
         ),
         do: send_resp(conn, 422, ~s({"error":{"veto":"submodules"}}))

    defp route(
           %{method: "GET", path_info: ["nodes", "runs", "broken-run", "seed.bundle"]} = conn,
           _test
         ) do
      conn = send_chunked(conn, 200)
      {:ok, _conn} = chunk(conn, String.duplicate("a", 1000))
      raise "the primary died mid-bundle"
    end

    defp route(%{method: "GET", path_info: ["nodes", "runs", run, "seed.bundle"]} = conn, test) do
      send(test, {:primary, :seed, run, conn.query_string})
      conn = send_chunked(conn, 200)
      {:ok, conn} = chunk(conn, String.duplicate("a", 100_000))
      {:ok, conn} = chunk(conn, "tail:" <> run)
      conn
    end

    defp route(%{method: "PUT", path_info: ["nodes", "runs", "gone-run", _]} = conn, _test) do
      {:ok, _body, conn} = read_all(conn, "")
      send_resp(conn, 404, ~s({"error":"not_found"}))
    end

    defp route(%{method: "PUT", path_info: ["nodes", "runs", run, kind]} = conn, test)
         when kind in ["checkout", "transcripts"] do
      {:ok, body, conn} = read_all(conn, "")

      send(
        test,
        {:primary, kind, run, body, get_req_header(conn, "content-type"),
         get_req_header(conn, "content-length")}
      )

      send_resp(conn, 200, ~s({"ingested":#{byte_size(body)}}))
    end

    defp route(conn, _test), do: send_resp(conn, 404, "")

    defp read_all(conn, acc) do
      case read_body(conn) do
        {:ok, data, conn} -> {:ok, acc <> data, conn}
        {:more, data, conn} -> read_all(conn, acc <> data)
      end
    end
  end

  setup do
    ca = Kit.ca()
    runs = start_supervised!({Runs, ca: ca, name: nil})

    primary =
      start_supervised!(
        {Bandit,
         plug: {Primary, test: self(), credential: @credential},
         scheme: :http,
         ip: @loopback,
         port: 0},
        id: :primary
      )

    {:ok, {_, primary_port}} = ThousandIsland.listener_info(primary)

    config = %Config{
      primary_url: "http://127.0.0.1:#{primary_port}",
      credential: @credential,
      req_options: []
    }

    server =
      start_supervised!(
        {PodServer,
         identity: Kit.server_identity(ca),
         ca: ca,
         runs: runs,
         config: config,
         ip: @loopback,
         port: 0,
         notify: self(),
         max_upload_bytes: 1_000_000}
      )

    %{ca: ca, runs: runs, port: PodServer.port(server)}
  end

  defp url(ctx, path), do: "https://localhost:#{ctx.port}#{path}"

  defp request(ctx, method, path, files, name),
    do: request(ctx, method, path, files, name, [])

  defp request(ctx, method, path, files, name, opts) do
    {:ok, resp} = request_result(ctx, method, path, files, name, opts)
    resp
  end

  defp request_result(ctx, method, path, files, name, opts) do
    transport =
      if files,
        do: Kit.client_opts(files, name, ctx.ca),
        else: Kit.client_opts_no_cert(ctx.ca)

    Req.request(
      [
        method: method,
        url: url(ctx, path),
        connect_options: [transport_opts: transport],
        retry: false,
        decode_body: false
      ] ++ opts
    )
  end

  defp boot(ctx, run \\ "run-1", ip \\ @loopback), do: Kit.boot!(ctx.runs, Kit.spec!(run), ip)

  describe "POST /boot" do
    test "hands the pod its tar for a valid nonce, with no client certificate", ctx do
      {:ok, nonce} = Runs.register(ctx.runs, Kit.spec!(), DateTime.add(DateTime.utc_now(), 600))
      :ok = Runs.bind_pod_ip(ctx.runs, "run-1", @loopback)

      resp = request(ctx, :post, "/boot", nil, nil, body: nonce)

      assert resp.status == 200
      assert Req.Response.get_header(resp, "cache-control") == ["no-store"]
      files = Kit.unpack(resp.body)
      assert files["secrets.env"] =~ "s3cret"
      assert Map.has_key?(files, "tls/control.key")
    end

    test "is single-use", ctx do
      {:ok, nonce} = Runs.register(ctx.runs, Kit.spec!(), DateTime.add(DateTime.utc_now(), 600))
      :ok = Runs.bind_pod_ip(ctx.runs, "run-1", @loopback)

      assert request(ctx, :post, "/boot", nil, nil, body: nonce).status == 200
      assert request(ctx, :post, "/boot", nil, nil, body: nonce).status == 403
    end

    test "refuses a nonce presented from another address, and spends it", ctx do
      {:ok, nonce} = Runs.register(ctx.runs, Kit.spec!(), DateTime.add(DateTime.utc_now(), 600))
      :ok = Runs.bind_pod_ip(ctx.runs, "run-1", {10, 42, 0, 61})

      assert request(ctx, :post, "/boot", nil, nil, body: nonce).status == 403
      :ok = Runs.bind_pod_ip(ctx.runs, "run-1", @loopback)
      assert request(ctx, :post, "/boot", nil, nil, body: nonce).status == 403
    end

    test "asks the pod to retry until its IP is known, without spending the nonce", ctx do
      {:ok, nonce} = Runs.register(ctx.runs, Kit.spec!(), DateTime.add(DateTime.utc_now(), 600))

      resp = request(ctx, :post, "/boot", nil, nil, body: nonce)
      assert resp.status == 409
      assert Req.Response.get_header(resp, "retry-after") == ["1"]

      :ok = Runs.bind_pod_ip(ctx.runs, "run-1", @loopback)
      assert request(ctx, :post, "/boot", nil, nil, body: nonce).status == 200
    end

    test "refuses a guess, an empty body and an oversized one", ctx do
      assert request(ctx, :post, "/boot", nil, nil, body: "nope").status == 403
      assert request(ctx, :post, "/boot", nil, nil, body: "").status == 403

      assert request(ctx, :post, "/boot", nil, nil, body: String.duplicate("x", 10_000)).status ==
               413
    end

    test "is refused for an expired nonce", ctx do
      ca = ctx.ca
      runs = start_supervised!({Runs, ca: ca, name: nil, boot_ttl_ms: 0}, id: :short_runs)

      {:ok, nonce} = Runs.register(runs, Kit.spec!(), DateTime.add(DateTime.utc_now(), 600))
      :ok = Runs.bind_pod_ip(runs, "run-1", @loopback)

      short =
        start_supervised!(
          {PodServer,
           identity: Kit.server_identity(ca),
           ca: ca,
           runs: runs,
           config: %Config{primary_url: "http://127.0.0.1:1", credential: "x"},
           ip: @loopback,
           port: 0},
          id: :short_server
        )

      resp = request(%{ctx | port: PodServer.port(short)}, :post, "/boot", nil, nil, body: nonce)
      assert resp.status == 403
    end
  end

  describe "the control routes" do
    test "refuse a request with no client certificate", ctx do
      boot(ctx)

      for {method, path} <- [
            get: "/seed.bundle",
            put: "/checkpoint",
            put: "/transcripts",
            get: "/commands"
          ] do
        assert request(ctx, method, path, nil, nil, body: "x").status == 401
      end
    end

    test "refuse a bridge leaf: only the control leaf speaks here", ctx do
      %{files: files} = boot(ctx)

      for {method, path} <- [get: "/seed.bundle", put: "/checkpoint", get: "/commands"] do
        assert request(ctx, method, path, files, "proxy", body: "x").status == 403
      end

      refute_received {:primary, _, _, _, _, _}
    end

    test "refuse everything once the run is released", ctx do
      %{files: files} = boot(ctx)
      :ok = Runs.release(ctx.runs, "run-1")

      assert request(ctx, :get, "/seed.bundle", files, "control").status == 403
    end

    test "answer 404 for a route that does not exist and 405 for a wrong method", ctx do
      %{files: files} = boot(ctx)

      assert request(ctx, :get, "/nope", files, "control").status == 404
      assert request(ctx, :get, "/checkpoint", files, "control").status == 405
      assert request(ctx, :put, "/boot", files, "control").status == 405
    end

    test "a run named in the URL is not a run: the certificate decides", ctx do
      %{files: files} = boot(ctx)

      assert request(ctx, :put, "/checkpoint/run-2", files, "control", body: "x").status == 404
      assert request(ctx, :get, "/seed.bundle?run=run-2", files, "control").status == 200
      assert_receive {:primary, :seed, "run-1", _}
      refute_received {:primary, :seed, "run-2", _}
    end
  end

  describe "GET /seed.bundle" do
    test "streams the primary's bundle for the certificate's run", ctx do
      %{files: files} = boot(ctx)

      resp = request(ctx, :get, "/seed.bundle?have=abc,def", files, "control")

      assert resp.status == 200
      assert byte_size(resp.body) == 100_000 + byte_size("tail:run-1")
      assert String.ends_with?(resp.body, "tail:run-1")
      assert_receive {:primary, :seed, "run-1", query}
      assert query == "have=abc%2Cdef"
    end

    test "a primary that breaks off mid-bundle is not passed off as a whole bundle", ctx do
      %{files: files} = Kit.boot!(ctx.runs, Kit.spec!("broken-run"), @loopback)

      assert {:error, _} = request_result(ctx, :get, "/seed.bundle", files, "control", [])
    end

    test "relays the primary's refusal (a veto) rather than a bundle", ctx do
      %{files: files} = Kit.boot!(ctx.runs, Kit.spec!("veto-run"), @loopback)

      resp = request(ctx, :get, "/seed.bundle", files, "control")

      assert resp.status == 422
      assert Jason.decode!(resp.body) == %{"error" => %{"veto" => "submodules"}}
    end
  end

  describe "PUT /checkpoint and /transcripts" do
    test "forward the body to the primary with the node credential, uncopied", ctx do
      %{files: files} = boot(ctx)
      bundle = :crypto.strong_rand_bytes(300_000)

      resp =
        request(ctx, :put, "/checkpoint", files, "control",
          body: bundle,
          headers: [{"content-type", "application/x-git-bundle"}]
        )

      assert resp.status == 200
      assert Jason.decode!(resp.body) == %{"ingested" => 300_000}

      assert_receive {:primary, "checkout", "run-1", ^bundle, ["application/x-git-bundle"],
                      ["300000"]}

      assert_receive {:pod_channel_upload, "run-1", :checkpoint, {:ok, 200}}
    end

    test "transcripts go to the transcripts route", ctx do
      %{files: files} = boot(ctx)

      resp =
        request(ctx, :put, "/transcripts", files, "control",
          body: "gz",
          headers: [{"content-type", "application/gzip"}]
        )

      assert resp.status == 200
      assert_receive {:primary, "transcripts", "run-1", "gz", ["application/gzip"], _}
      assert_receive {:pod_channel_upload, "run-1", :transcripts, {:ok, 200}}
    end

    test "refuse an upload over the limit before reading it", ctx do
      %{files: files} = boot(ctx)

      resp =
        request(ctx, :put, "/checkpoint", files, "control",
          body: String.duplicate("a", 1_000_001)
        )

      assert resp.status == 413
      refute_received {:primary, "checkout", _, _, _, _}
    end

    test "refuse an upload with no length", ctx do
      %{files: files} = boot(ctx)
      chunks = Stream.map(["a", "b"], & &1)

      resp = request(ctx, :put, "/checkpoint", files, "control", body: chunks)

      assert resp.status == 411
    end

    test "a primary that rejects the bundle is relayed, not swallowed", ctx do
      %{files: files} = Kit.boot!(ctx.runs, Kit.spec!("gone-run"), @loopback)

      resp = request(ctx, :put, "/checkpoint", files, "control", body: "x")

      assert resp.status == 404
      assert_receive {:pod_channel_upload, "gone-run", :checkpoint, {:error, {:rejected, 404}}}
    end
  end

  describe "GET /commands" do
    test "returns queued commands, empty when the wait runs out", ctx do
      %{files: files} = boot(ctx)

      :ok = Runs.push_command(ctx.runs, "run-1", %{"op" => "checkpoint"})
      resp = request(ctx, :get, "/commands?wait=1", files, "control")
      assert Jason.decode!(resp.body) == %{"commands" => [%{"op" => "checkpoint"}]}

      resp = request(ctx, :get, "/commands?wait=1", files, "control")
      assert Jason.decode!(resp.body) == %{"commands" => []}
    end

    test "waits for a command that arrives", ctx do
      %{files: files} = boot(ctx)
      task = Task.async(fn -> request(ctx, :get, "/commands?wait=20", files, "control") end)

      assert_eventually(fn -> Runs.waiting(ctx.runs, "run-1") == 1 end)
      :ok = Runs.push_command(ctx.runs, "run-1", %{"op" => "stop"})

      assert Jason.decode!(Task.await(task).body) == %{"commands" => [%{"op" => "stop"}]}
    end
  end

  defp assert_eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never held")

      true ->
        receive do
        after
          20 -> assert_eventually(fun, tries - 1)
        end
    end
  end
end
