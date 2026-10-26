defmodule Arbiter.Worker.CliFetcher.SchedulerTest do
  use Arbiter.DataCase, async: false

  import Req.Test, only: [set_req_test_to_shared: 1]

  alias Arbiter.Settings
  alias Arbiter.Worker.CliFetcher.Cache
  alias Arbiter.Worker.CliFetcher.Fixtures
  alias Arbiter.Worker.CliFetcher.Scheduler

  @moduletag :tmp_dir

  setup :set_req_test_to_shared

  setup ctx do
    on_exit(fn ->
      Settings.set_worker_cli_versions(nil)
      Settings.set_worker_cli_set_hold(nil)
    end)

    fetch_opts =
      Fixtures.base_opts(Path.join(ctx.tmp_dir, "cli-cache"),
        work_dir: ctx.tmp_dir,
        arb_version: "1.2.3"
      )

    routes =
      Fixtures.claude_routes(["2.1.308", "2.1.310"])
      |> Map.merge(Fixtures.codex_routes(["0.164.0"]))
      |> Map.merge(Fixtures.arb_routes("1.2.3"))

    Fixtures.serve(routes)
    {:ok, fetch_opts: fetch_opts}
  end

  defp start(ctx, extra \\ []) do
    opts =
      [name: nil, enabled: true, initial_delay_ms: :infinity, fetch_opts: ctx.fetch_opts] ++ extra

    start_supervised!({Scheduler, opts})
  end

  test "is off unless enabled" do
    assert :ignore = Scheduler.start_link(enabled: false, name: nil)
  end

  test "run_now bumps the pins, caches every CLI including arb, and reports", ctx do
    {:ok, _} = Settings.set_worker_cli_versions(%{"claude" => "2.1.308", "codex" => "0.164.0"})
    pid = start(ctx)

    report = Scheduler.run_now(pid)
    assert report.bump["claude"] == {:bumped, "2.1.308", "2.1.310"}
    assert report.bump["codex"] == {:current, "0.164.0"}
    assert report.ensured == %{"claude" => :ok, "codex" => :ok, "arb" => :ok}

    for {name, version} <- [{"claude", "2.1.310"}, {"codex", "0.164.0"}, {"arb", "1.2.3"}] do
      assert {:ok, _} = Cache.lookup(name, version, ctx.fetch_opts)
    end

    status = Scheduler.status(pid)
    assert status.enabled
    assert status.latest == %{"claude" => "2.1.310", "codex" => "0.164.0"}
    assert %DateTime{} = status.checked_at
  end

  test "while held it still reports what is available but changes nothing", ctx do
    {:ok, _} = Settings.set_worker_cli_versions(%{"claude" => "2.1.308", "codex" => "0.164.0"})
    {:ok, _} = Settings.set_worker_cli_set_hold("a1b2c3d4")
    pid = start(ctx)

    report = Scheduler.run_now(pid)
    assert report.bump["claude"] == {:held, "a1b2c3d4"}
    assert Settings.worker_cli_versions()["claude"] == "2.1.308"
    assert Scheduler.status(pid).latest["claude"] == "2.1.310"
  end

  test "an upstream failure is reported, not raised", ctx do
    Fixtures.serve(%{})
    pid = start(ctx)

    report = Scheduler.run_now(pid)
    assert {:error, _} = report.bump["claude"]
    assert Process.alive?(pid)
    assert Scheduler.status(pid).latest == %{"claude" => nil, "codex" => nil}
  end

  test "status/1 of a scheduler that is not running is a disabled placeholder" do
    assert %{enabled: false, checked_at: nil} = Scheduler.status(:nonexistent_cli_scheduler)
  end
end
