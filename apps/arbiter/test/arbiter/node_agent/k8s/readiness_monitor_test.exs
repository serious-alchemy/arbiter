defmodule Arbiter.NodeAgent.K8s.ReadinessMonitorTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.ReadinessMonitor
  alias Arbiter.Test.FakeK8sApi
  alias Arbiter.Test.K8sPodFixtures, as: Fx

  @all_closed """
  probe api closed
  probe controller_port closed
  probe foreign closed
  probe internet closed
  probe node closed
  probe bridge open
  canary done
  """

  setup do
    cluster = FakeK8sApi.start!(namespace: "arbiter-workers")
    FakeK8sApi.set_clock(cluster.api, DateTime.utc_now())
    FakeK8sApi.put_quota(cluster.api, quota())
    clock = start_supervised!({Agent, fn -> 0 end})
    Map.put(cluster, :clock, clock)
  end

  defp quota do
    hard = %{"pods" => "6", "requests.cpu" => "6", "requests.memory" => "12Gi"}

    %{
      "metadata" => %{"name" => "q"},
      "spec" => %{"hard" => hard},
      "status" => %{"hard" => hard, "used" => %{}}
    }
  end

  defp script(api, log, phase \\ "Succeeded") do
    FakeK8sApi.on_create(api, fn pod ->
      {Map.put(pod, "status", %{"phase" => phase}), String.split(log, "\n", trim: true)}
    end)
  end

  defp start!(%{client: client, clock: clock}, extra \\ []) do
    opts =
      Keyword.merge(
        [
          client: client,
          config_fun: fn -> {:ok, Fx.config()} end,
          image: "#{Fx.registry()}/beam@sha256:#{Fx.digest()}",
          targets: %{api: "10.43.0.1:443"},
          interval_ms: nil,
          stale_after_ms: 1_000,
          poll_ms: 5,
          timeout_ms: 500,
          now_ms_fun: fn -> Agent.get(clock, & &1) end,
          notify: self()
        ],
        extra
      )

    start_supervised!({ReadinessMonitor, opts})
  end

  defp check(report, id), do: Enum.find(report.checks, &(&1["id"] == id))

  test "fails closed before the first canary has run", ctx do
    script(ctx.api, @all_closed)
    server = start!(ctx, autostart: false)

    report = ReadinessMonitor.report(server)
    assert report.degraded == ["netpol_unenforced"]
    assert check(report, "netpol")["status"] == "fail"
    assert report.at == nil
  end

  test "runs at start and clears the flag when the policy is enforced", ctx do
    script(ctx.api, @all_closed)
    server = start!(ctx)

    assert_receive {:k8s_readiness, ^server, report}, 5_000
    assert report.degraded == []
    assert check(report, "netpol")["status"] == "ok"

    assert Enum.map(report.checks, & &1["id"]) |> Enum.sort() ==
             ~w(clock netpol priority_class psa quota registry_pull)

    assert ReadinessMonitor.report(server).degraded == []
  end

  test "an unenforced cluster raises degraded: netpol_unenforced", ctx do
    script(ctx.api, String.replace(@all_closed, "probe internet closed", "probe internet open"))
    server = start!(ctx)

    assert_receive {:k8s_readiness, ^server, report}, 5_000
    assert report.degraded == ["netpol_unenforced"]
    assert %{"status" => "fail", "detail" => detail} = check(report, "netpol")
    assert detail =~ "internet"
  end

  test "an unenforced verdict replaces an earlier enforced one at once", ctx do
    script(ctx.api, @all_closed)
    server = start!(ctx)
    assert_receive {:k8s_readiness, ^server, %{degraded: []}}, 5_000

    script(ctx.api, String.replace(@all_closed, "probe node closed", "probe node open"))
    assert %{degraded: ["netpol_unenforced"]} = ReadinessMonitor.refresh(server)
  end

  test "an inconclusive run keeps a fresh enforced verdict, flagged as a warning", ctx do
    script(ctx.api, @all_closed)
    server = start!(ctx)
    assert_receive {:k8s_readiness, ^server, %{degraded: []}}, 5_000

    FakeK8sApi.fail_next(ctx.api, :create, {403, "exceeded quota: arbiter-workers"})
    Agent.update(ctx.clock, fn _ -> 500 end)

    report = ReadinessMonitor.refresh(server)
    assert report.degraded == []
    assert %{"status" => "warn", "detail" => detail} = check(report, "netpol")
    assert detail =~ "kept"
  end

  test "an inconclusive run does not keep a stale verdict", ctx do
    script(ctx.api, @all_closed)
    server = start!(ctx)
    assert_receive {:k8s_readiness, ^server, %{degraded: []}}, 5_000

    FakeK8sApi.fail_next(ctx.api, :create, {403, "exceeded quota: arbiter-workers"})
    Agent.update(ctx.clock, fn _ -> 5_000 end)

    report = ReadinessMonitor.refresh(server)
    assert report.degraded == ["netpol_unenforced"]
    assert check(report, "netpol")["status"] == "fail"
  end

  test "an inconclusive first run is unenforced", ctx do
    FakeK8sApi.fail_next(ctx.api, :create, {403, "exceeded quota: arbiter-workers"})
    server = start!(ctx)

    assert_receive {:k8s_readiness, ^server, report}, 5_000
    assert report.degraded == ["netpol_unenforced"]
    assert check(report, "netpol")["detail"] =~ "not proven"
  end

  test "no controller config yet is inconclusive, not a crash", ctx do
    server = start!(ctx, config_fun: fn -> {:error, :no_config} end)

    assert_receive {:k8s_readiness, ^server, report}, 5_000
    assert report.degraded == ["netpol_unenforced"]
    assert check(report, "netpol")["detail"] =~ "no_config"
  end

  test "an exit or throw inside a run is inconclusive, not a crash of the monitor", ctx do
    server = start!(ctx, config_fun: fn -> exit(:call_timeout) end)

    assert_receive {:k8s_readiness, ^server, report}, 5_000
    assert report.degraded == ["netpol_unenforced"]
    assert check(report, "netpol")["detail"] =~ "call_timeout"
    assert %{degraded: ["netpol_unenforced"]} = ReadinessMonitor.report(server)
  end

  test "a throw inside a run is inconclusive too", ctx do
    server = start!(ctx, config_fun: fn -> throw(:oops) end)

    assert_receive {:k8s_readiness, ^server, %{degraded: ["netpol_unenforced"]}}, 5_000
    assert %{degraded: ["netpol_unenforced"]} = ReadinessMonitor.report(server)
  end

  test "a config change re-runs the canary", ctx do
    script(ctx.api, @all_closed)
    server = start!(ctx)
    assert_receive {:k8s_readiness, ^server, _}, 5_000
    posts = fn -> ctx.api |> FakeK8sApi.requests() |> Enum.count(&(&1.method == "POST")) end
    before = posts.()

    send(server, {:controller_config, :loader, %{}})
    assert_receive {:k8s_readiness, ^server, _}, 5_000
    assert posts.() > before
  end

  test "re-runs on its interval", ctx do
    script(ctx.api, @all_closed)
    server = start!(ctx, interval_ms: 30)

    assert_receive {:k8s_readiness, ^server, _}, 5_000
    assert_receive {:k8s_readiness, ^server, _}, 5_000
  end

  test "listens on the canary's controller port so a closed probe means something", ctx do
    script(ctx.api, @all_closed)
    server = start!(ctx, listen_port: 0)

    port = ReadinessMonitor.listen_port(server)
    assert is_integer(port) and port > 0
    assert {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
    :gen_tcp.close(socket)
  end

  test "hello_readiness/1 is the podman-shaped report with a ready flag", ctx do
    script(ctx.api, @all_closed)
    server = start!(ctx)
    assert_receive {:k8s_readiness, ^server, report}, 5_000

    assert %{"ready" => true, "checks" => checks} = ReadinessMonitor.hello_readiness(report)
    assert Enum.all?(checks, &is_map_key(&1, "status"))

    failing = %{report | checks: [%{"id" => "netpol", "status" => "fail"} | report.checks]}
    assert %{"ready" => false} = ReadinessMonitor.hello_readiness(failing)
  end
end
