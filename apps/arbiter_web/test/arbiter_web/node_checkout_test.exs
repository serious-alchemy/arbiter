defmodule ArbiterWeb.NodeCheckoutTest do
  @moduledoc """
  RW11 (`docs/design/remote-workers.md` §9): the primary's two checkout endpoints,
  `GET /nodes/runs/:run/seed.bundle` and `PUT /nodes/runs/:run/checkout`, over the
  real router, `Session` and `Arbiter.Nodes.Checkout` with real git on fixture
  repos. The node half is the real `Arbiter.NodeAgent.Checkout`.
  """
  use ArbiterWeb.ConnCase, async: false

  import ArbiterWeb.NodeFixtures

  alias Arbiter.NodeAgent.Checkout, as: Shadow
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{RateLimit, Registry, Session}

  @moduletag :tmp_dir
  @branch "arbiter/run"
  @run "run-1"

  setup %{tmp_dir: tmp} do
    use_data_home!(Path.join(tmp, "data"))
    RateLimit.reset()
    Application.put_env(:arbiter, :node_primary_version, "1.2.3")
    on_exit(fn -> Application.delete_env(:arbiter, :node_primary_version) end)

    on_exit(fn ->
      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    %{node: node, credential: credential} = enroll!("co-node")
    %{node: other, credential: other_credential} = enroll!("other-node")
    node = Nodes.get_node(node.id)
    other = Nodes.get_node(other.id)

    home = Path.join(tmp, "home")
    base = home!(home)

    ctx = %{home: home, branch: @branch, base: "main", seeded_paths: []}
    {:ok, %{pid: pid}} = attach!(node)
    place!(pid, @run, ctx)
    {:ok, %{pid: other_pid}} = attach!(other)

    %{
      node: node,
      tmp: tmp,
      home: home,
      base: base,
      pid: pid,
      auth: auth(credential),
      other_auth: auth(other_credential),
      other_pid: other_pid
    }
  end

  defp enroll!(name) do
    {:ok, %{token: token}} = Nodes.mint_join_token([name: name], "operator:test")
    {:ok, resp} = Nodes.redeem_join_token(token)
    resp
  end

  defp attach!(node) do
    Registry.attach(node, self(), %{
      "agent_version" => "1.2.3",
      "proto" => 1,
      "arch" => "x86_64",
      "caps" => %{"backend" => "podman"},
      "capacity" => %{"cpus" => 8, "mem_total" => 16_000_000_000, "suggestion" => 4},
      "runs" => []
    })
  end

  defp place!(pid, run, ctx) do
    owner = self()
    task = Task.async(fn -> Session.assign(pid, run, %{"run" => run}, owner, checkout: ctx) end)
    assert_receive {:node_session, {:push, "assign", _}}
    Session.node_event(pid, "run.ready", %{"run" => run})
    assert {:ok, _} = Task.await(task)
  end

  defp auth(credential), do: [{"authorization", "Bearer #{credential}"}]

  defp request(method, path, headers, body \\ nil) do
    headers
    |> Enum.reduce(Phoenix.ConnTest.build_conn(), fn {k, v}, c -> put_req_header(c, k, v) end)
    |> Phoenix.ConnTest.dispatch(@endpoint, method, path, body)
  end

  defp upload(path, headers, body),
    do:
      request(
        :put,
        path,
        [{"content-type", "application/x-git-bundle"}, {"content-length", "#{byte_size(body)}"}] ++
          headers,
        body
      )

  defp git!(dir, args, env \\ []) do
    {out, 0} =
      System.cmd("git", args,
        cd: dir,
        env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}] ++ env,
        stderr_to_stdout: true
      )

    String.trim_trailing(out)
  end

  defp home!(home) do
    File.mkdir_p!(Path.join(home, "lib"))
    git!(home, ["init", "-q", "-b", "main"])
    git!(home, ["config", "user.email", "t@example.com"])
    git!(home, ["config", "user.name", "t"])
    File.write!(Path.join(home, "lib/a.txt"), "a\n")
    File.write!(Path.join(home, "run.sh"), "#!/bin/sh\n")
    File.chmod!(Path.join(home, "run.sh"), 0o755)
    git!(home, ["add", "-A"])
    git!(home, ["commit", "-q", "-m", "base"])
    base = git!(home, ["rev-parse", "HEAD"])
    git!(home, ["checkout", "-q", "-b", @branch])
    base
  end

  # The node side: GET the seed bundle (through the endpoint), build the shadow.
  defp seed!(c, auth, run \\ @run) do
    conn = request(:get, "/nodes/runs/#{run}/seed.bundle", auth)
    assert conn.status == 200
    bundle = Path.join(c.tmp, "seed.bundle")
    File.write!(bundle, conn.resp_body)

    {:ok, info} =
      Shadow.seed(%{
        store: Path.join(c.tmp, "node/store.git"),
        shadow: Path.join(c.tmp, "node/shadow"),
        bundle: bundle,
        run: run,
        branch: @branch,
        base: "main"
      })

    {Path.join(c.tmp, "node/shadow"), info}
  end

  describe "GET /nodes/runs/:run/seed.bundle" do
    test "serves the run's seed bundle to the node it is assigned to", c do
      conn = request(:get, "/nodes/runs/#{@run}/seed.bundle", c.auth)
      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/x-git-bundle"
      assert conn.resp_body =~ "# v2 git bundle"
      assert git!(c.home, ["rev-parse", @branch]) == c.base
    end

    test "is thin against ?have=", c do
      full = request(:get, "/nodes/runs/#{@run}/seed.bundle", c.auth)
      File.write!(Path.join(c.home, "lib/b.txt"), String.duplicate("b\n", 1000))
      git!(c.home, ["add", "-A"])
      git!(c.home, ["commit", "-q", "-m", "more"])

      thin = request(:get, "/nodes/runs/#{@run}/seed.bundle?have=#{c.base}", c.auth)
      assert thin.status == 200
      assert byte_size(thin.resp_body) < byte_size(full.resp_body) + 600
      assert thin.resp_body != full.resp_body
    end

    test "needs a node credential, and a run assigned to the caller", c do
      assert request(:get, "/nodes/runs/#{@run}/seed.bundle", []).status == 401
      assert request(:get, "/nodes/runs/#{@run}/seed.bundle", c.other_auth).status == 404
      assert request(:get, "/nodes/runs/nope/seed.bundle", c.auth).status == 404
      assert request(:get, "/nodes/runs/..%2F..%2Fx/seed.bundle", c.auth).status == 404
    end

    test "a repo with a submodule is vetoed (422)", c do
      git!(c.home, [
        "update-index",
        "--add",
        "--cacheinfo",
        "160000,#{String.duplicate("a", 40)},vendor/dep"
      ])

      git!(c.home, ["commit", "-q", "-m", "submodule"])
      conn = request(:get, "/nodes/runs/#{@run}/seed.bundle", c.auth)
      assert conn.status == 422
      assert %{"error" => %{"veto" => "submodule"}} = json_response(conn, 422)
    end
  end

  describe "PUT /nodes/runs/:run/checkout" do
    defp package!(c, shadow, info, opts \\ []) do
      dest = Path.join(c.tmp, "up.bundle")

      {:ok, up} =
        Shadow.package(
          Map.merge(
            %{shadow: shadow, run: @run, branch: @branch, known: info.known, dest: dest},
            Map.new(opts)
          )
        )

      File.read!(up.path)
    end

    test "ingests the bundle into the home clone and answers the collector", c do
      {shadow, info} = seed!(c, c.auth)
      File.write!(Path.join(shadow, "lib/new.txt"), "from the node\n")
      File.write!(Path.join(shadow, ".mcp.json"), "{}\n")
      body = package!(c, shadow, info)

      waiter = Task.async(fn -> Session.collect(c.pid, @run, :checkout, 10_000) end)
      assert_receive {:node_session, {:push, "collect", _}}

      conn = upload("/nodes/runs/#{@run}/checkout", c.auth, body)
      assert %{"head" => head, "filtered" => [".mcp.json"]} = json_response(conn, 200)
      assert head == c.base
      assert File.read!(Path.join(c.home, "lib/new.txt")) == "from the node\n"
      refute File.exists?(Path.join(c.home, ".mcp.json"))

      assert {:ok, %{head: ^head}} = Task.await(waiter)
    end

    test "a bundle carrying .git/config is rejected with 422 and recorded", c do
      {shadow, info} = seed!(c, c.auth)

      evil =
        Path.join(c.tmp, "evil-blob")
        |> tap(&File.write!(&1, "[core]\n\tfsmonitor = touch /tmp/pwned\n"))

      blob = git!(shadow, ["hash-object", "-w", "--literally", evil])
      inner = Path.join(c.tmp, "inner")
      File.write!(inner, "100644 config\0" <> Base.decode16!(blob, case: :lower))
      inner_sha = git!(shadow, ["hash-object", "-w", "-t", "tree", "--literally", inner])
      outer = Path.join(c.tmp, "outer")
      File.write!(outer, "40000 .git\0" <> Base.decode16!(inner_sha, case: :lower))
      outer_sha = git!(shadow, ["hash-object", "-w", "-t", "tree", "--literally", outer])
      commit = git!(shadow, ["commit-tree", "-m", "evil", "-p", c.base, outer_sha])
      git!(shadow, ["update-ref", "refs/arbiter/snapshot/#{@run}", commit])
      bundle = Path.join(c.tmp, "evil.bundle")
      git!(shadow, ["bundle", "create", bundle, "refs/arbiter/snapshot/#{@run}", "^" <> hd(info.known)])

      conn = upload("/nodes/runs/#{@run}/checkout", c.auth, File.read!(bundle))
      assert conn.status == 422
      assert git!(c.home, ["rev-parse", @branch]) == c.base
      assert git!(c.home, ["for-each-ref", "refs/arbiter"]) == ""
      _ = Session.snapshot(c.pid)
      assert :checkout_rejected in Enum.map(Nodes.events(node_id: c.node.id), & &1.kind)
    end

    test "the size cap: a declared length over it is refused before the body is read", c do
      Application.put_env(:arbiter, :node_checkout_max_bytes, 1_000)
      on_exit(fn -> Application.delete_env(:arbiter, :node_checkout_max_bytes) end)

      conn =
        request(:put, "/nodes/runs/#{@run}/checkout", [
          {"content-type", "application/x-git-bundle"},
          {"content-length", "5000"} | c.auth
        ])

      assert conn.status == 413

      # and the cap holds for a body larger than it declared
      conn =
        request(
          :put,
          "/nodes/runs/#{@run}/checkout",
          [{"content-type", "application/x-git-bundle"}, {"content-length", "10"} | c.auth],
          String.duplicate("x", 5_000)
        )

      assert conn.status in [400, 413]
    end

    test "needs a length, a credential, and a run assigned to the caller", c do
      assert upload("/nodes/runs/#{@run}/checkout", [], "x").status == 401
      assert upload("/nodes/runs/#{@run}/checkout", c.other_auth, "x").status == 404
      assert upload("/nodes/runs/nope/checkout", c.auth, "x").status == 404

      conn =
        request(:put, "/nodes/runs/#{@run}/checkout", [{"content-type", "application/x-git-bundle"} | c.auth], "x")

      assert conn.status == 411
    end

    test "garbage is a 422, not a crash", c do
      conn = upload("/nodes/runs/#{@run}/checkout", c.auth, "this is not a bundle")
      assert conn.status == 422
    end
  end
end
