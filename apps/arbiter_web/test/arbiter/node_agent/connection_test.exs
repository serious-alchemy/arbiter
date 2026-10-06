defmodule Arbiter.NodeAgent.ConnectionTest do
  @moduledoc """
  The agent tree end to end against a real Phoenix endpoint under Bandit
  (docs/design/remote-workers.md §4.2, §6): connect, `hello` with version and
  readiness, heartbeats, reconnect with backoff, self-fence, and self-upgrade
  through the atomic `current` symlink. The server half is a test stand-in
  (`ArbiterWeb.FakeNode`); the real one is RW6.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Arbiter.NodeAgent.Config
  alias Arbiter.NodeAgent.Connection
  alias Arbiter.NodeAgent.Status
  alias Arbiter.NodeAgent.Upgrader
  alias ArbiterWeb.FakeNode

  @credential "arbn_node123." <> String.duplicate("A", 52)

  @readiness %{
    ready: true,
    installed: true,
    checks: [%{id: "podman", name: "podman", status: "ok", detail: "podman 5.8.7", hint: nil}]
  }

  setup do
    home = Path.join(System.tmp_dir!(), "arb-conn-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, "releases/1.0.0/bin"))
    File.write!(Path.join(home, "releases/1.0.0/bin/arbiter"), "old")
    File.ln_s!("releases/1.0.0", Path.join(home, "current"))
    on_exit(fn -> File.rm_rf!(home) end)

    Application.put_env(:arbiter_web, :fake_node_token, @credential)
    Application.put_env(:arbiter_web, :fake_node_test_pid, self())

    Application.put_env(:arbiter_web, :fake_node_hello_ok, %{
      "hb_interval" => 0.03,
      "fence_after" => 60
    })

    on_exit(fn ->
      for key <-
            ~w(fake_node_token fake_node_test_pid fake_node_hello_ok fake_node_style fake_node_ack? fake_node_tarball)a,
          do: Application.delete_env(:arbiter_web, key)
    end)

    start_supervised!({Phoenix.PubSub, name: ArbiterWeb.FakeNode.PubSub})
    start_supervised!(FakeNode.endpoint_spec())

    %{home: home, port: FakeNode.port()}
  end

  # Starts the agent's own tree pieces under the test supervisor, with unique
  # names so a failed test cannot leak a registered process into the next.
  defp start_agent(ctx, overrides \\ []) do
    test_pid = self()

    {:ok, config} =
      Config.load(
        [
          env: %{},
          primary_url: "http://127.0.0.1:#{ctx.port}",
          node_home: ctx.home,
          read_credential: fn _ -> {:ok, @credential} end,
          version: "1.0.0",
          hb_interval_ms: 30,
          fence_after_ms: 5_000,
          idle_poll_ms: 5,
          backoff: [base: 20, max: 80],
          readiness_fun: fn ->
            send(test_pid, :readiness_probed)
            @readiness
          end,
          halt_fun: fn -> send(test_pid, :halted) end
        ] ++ overrides
      )

    start_supervised!({Task.Supervisor, name: Arbiter.NodeAgent.TaskSupervisor})
    start_supervised!({Status, path: config.status_path})
    start_supervised!({Upgrader, config: config})
    conn = start_supervised!({Connection, config: config})
    {conn, config}
  end

  defp status(config), do: config.status_path |> File.read!() |> Jason.decode!()

  test "connects with the credential and sends hello with version, proto and readiness", ctx do
    start_agent(ctx)

    assert_receive {:fake_node, :socket,
                    {:connect, %{"proto" => "1", "agent_version" => "1.0.0"}}},
                   5_000

    assert_receive {:fake_node, :joined, "node:node123"}, 5_000
    assert_receive {:fake_node, :hello, hello}, 5_000

    assert hello["agent_version"] == "1.0.0"
    assert hello["proto"] == 1
    assert hello["kind"] == "machine"
    assert hello["inventory"] == %{"runs" => []}
    assert hello["caps"]["backend"] == "podman"
    assert is_binary(hello["arch"])
    assert hello["capacity"]["cpus"] >= 1

    assert hello["readiness"] == %{
             "ready" => true,
             "installed" => true,
             "checks" => [
               %{
                 "id" => "podman",
                 "name" => "podman",
                 "status" => "ok",
                 "detail" => "podman 5.8.7",
                 "hint" => nil
               }
             ]
           }
  end

  test "heartbeats at the interval hello_ok asks for, and records readiness in the status file",
       ctx do
    {_conn, config} = start_agent(ctx)

    assert_receive {:fake_node, :hb, %{"seq" => 1, "runs" => []}}, 5_000
    assert_receive {:fake_node, :hb, %{"seq" => 2}}, 5_000
    assert_receive {:fake_node, :hb, %{"seq" => 3}}, 5_000

    st = status(config)
    assert st["state"] == "ready"
    assert st["agent_version"] == "1.0.0"
    assert st["node_id"] == "node123"
    assert st["readiness_ready"] == true
    refute inspect(st) =~ "AAAA"
  end

  test "hello_ok and hb_ack delivered as server pushes work too", ctx do
    Application.put_env(:arbiter_web, :fake_node_style, :push)
    {_conn, config} = start_agent(ctx)

    assert_receive {:fake_node, :hb, %{"seq" => 2}}, 5_000
    wait_until(fn -> status(config)["last_hb_ack_at"] != nil end)
    assert status(config)["state"] == "ready"
  end

  test "reconnects with backoff after the server drops the socket, and says hello again", ctx do
    {conn, _config} = start_agent(ctx)
    assert_receive {:fake_node, :hello, _}, 5_000
    assert_receive {:fake_node, :hb, _}, 5_000

    flush_fake_node()
    FakeNode.Endpoint.broadcast("node_socket:fake", "disconnect", %{})

    assert_receive {:fake_node, :hello, _}, 5_000
    assert_receive {:fake_node, :hb, _}, 5_000
    assert Connection.info(conn).phase == :ready
    # readiness is cached across reconnects: the (container-starting) probe ran once
    assert_received :readiness_probed
    refute_received :readiness_probed
  end

  test "keeps retrying while the primary is down, with a growing attempt count, then recovers",
       ctx do
    {conn, config} = start_agent(ctx)
    assert_receive {:fake_node, :hello, _}, 5_000

    stop_supervised!(FakeNode.Endpoint)

    wait_until(fn -> status(config)["attempt"] >= 3 end)
    assert status(config)["state"] == "backoff"

    assert status(config)["last_error"] =~ "closed" or
             status(config)["last_error"] =~ "connect failed"

    refute Connection.info(conn).phase == :ready

    start_supervised!(FakeNode.endpoint_spec(port: ctx.port))
    assert_receive {:fake_node, :hello, _}, 5_000
    wait_until(fn -> Connection.info(conn).phase == :ready end)
    # attempt resets on hello_ok
    assert Connection.info(conn).attempt == 0
  end

  test "a primary that refuses the credential is retried, never crashes the agent", ctx do
    Application.put_env(:arbiter_web, :fake_node_token, "arbn_node123.rotated")
    {conn, config} = start_agent(ctx)

    wait_until(fn -> (status(config)["attempt"] || 0) >= 2 end)
    assert Process.alive?(conn)
    refute_received {:fake_node, :hello, _}
  end

  test "self-fences and reconnects when the primary stops acknowledging heartbeats", ctx do
    Application.put_env(:arbiter_web, :fake_node_ack?, false)
    {_conn, config} = start_agent(ctx, fence_after_ms: 120)
    # the server grants only what hello_ok says; the test's hello_ok must not override it
    Application.put_env(:arbiter_web, :fake_node_hello_ok, %{
      "hb_interval" => 0.03,
      "fence_after" => 0.12
    })

    assert_receive {:fake_node, :hello, _}, 5_000
    assert_receive {:fake_node, :hb, _}, 5_000

    wait_until(fn -> status(config)["fenced_at"] != nil end)
    # and it came back for another hello rather than sitting fenced
    assert_receive {:fake_node, :hello, _}, 5_000
  end

  describe "version skew" do
    defp tarball(version) do
      dir = Path.join(System.tmp_dir!(), "arb-conn-tar-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "arbiter/bin"))
      File.write!(Path.join(dir, "arbiter/bin/arbiter"), "#!/bin/sh\necho #{version}\n")
      out = dir <> ".tar.gz"

      :ok =
        :erl_tar.create(
          String.to_charlist(out),
          [{~c"arbiter/bin/arbiter", String.to_charlist(Path.join(dir, "arbiter/bin/arbiter"))}],
          [:compressed]
        )

      File.rm_rf!(dir)
      out
    end

    test "hello_ok carrying upgrade{version, sha256} downloads, flips current and restarts",
         ctx do
      path = tarball("2.0.0")
      on_exit(fn -> File.rm(path) end)
      sha = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

      Application.put_env(:arbiter_web, :fake_node_tarball, {path, "2.0.0"})

      Application.put_env(:arbiter_web, :fake_node_hello_ok, %{
        "hb_interval" => 0.03,
        "upgrade" => %{"version" => "2.0.0", "sha256" => sha}
      })

      {_conn, config} = start_agent(ctx)

      assert_receive {:fake_node, :download, "2.0.0.tar.gz"}, 5_000
      assert_receive :halted, 5_000

      assert File.read_link!(Path.join(ctx.home, "current")) == "releases/2.0.0"
      assert File.read!(Path.join(ctx.home, "releases/2.0.0/bin/arbiter")) =~ "echo 2.0.0"
      assert File.read!(Path.join(ctx.home, "upgrade.pending")) =~ "to=2.0.0"
      assert status(config)["agent_version"] == "1.0.0"
    end

    test "a hello_ok upgrade to the version already running is ignored", ctx do
      Application.put_env(:arbiter_web, :fake_node_hello_ok, %{
        "hb_interval" => 0.03,
        "upgrade" => %{"version" => "1.0.0", "sha256" => String.duplicate("0", 64)}
      })

      start_agent(ctx)
      assert_receive {:fake_node, :hb, %{"seq" => 2}}, 5_000
      refute_received :halted
      refute_received {:fake_node, :download, _}
    end

    test "a checksum mismatch leaves current alone, keeps heartbeating and reports the failure",
         ctx do
      path = tarball("2.0.0")
      on_exit(fn -> File.rm(path) end)
      Application.put_env(:arbiter_web, :fake_node_tarball, {path, "2.0.0"})

      Application.put_env(:arbiter_web, :fake_node_hello_ok, %{
        "hb_interval" => 0.03,
        "upgrade" => %{"version" => "2.0.0", "sha256" => String.duplicate("0", 64)}
      })

      {_conn, config} = start_agent(ctx)

      wait_until(fn -> get_in(status(config), ["upgrade", "state"]) == "failed" end)
      assert File.read_link!(Path.join(ctx.home, "current")) == "releases/1.0.0"
      assert get_in(status(config), ["upgrade", "error"]) =~ "sha256_mismatch"
      refute_received :halted
      assert_receive {:fake_node, :hb, %{"seq" => 3}}, 5_000
    end

    test "the first hello_ok after an upgrade confirms it", ctx do
      File.write!(Path.join(ctx.home, "upgrade.pending"), "from=releases/0.9.0\nto=1.0.0\nat=1\n")
      start_agent(ctx)

      assert_receive {:fake_node, :hello, _}, 5_000
      wait_until(fn -> File.exists?(Path.join(ctx.home, "confirmed")) end)
      refute File.exists?(Path.join(ctx.home, "upgrade.pending"))
    end
  end

  defp flush_fake_node do
    receive do
      {:fake_node, _, _} -> flush_fake_node()
    after
      0 -> :ok
    end
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(25) && wait_until(fun, tries - 1)
    end
  end
end
