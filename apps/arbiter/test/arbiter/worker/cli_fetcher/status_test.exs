defmodule Arbiter.Worker.CliFetcher.StatusTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Settings
  alias Arbiter.Worker.CliFetcher
  alias Arbiter.Worker.CliFetcher.Fixtures
  alias Arbiter.Worker.CliFetcher.Status

  @moduletag :tmp_dir

  setup ctx do
    on_exit(fn ->
      Settings.set_worker_cli_versions(nil)
      Settings.set_worker_cli_manual(nil)
      Settings.set_worker_cli_set_hold(nil)
    end)

    {:ok, opts: Fixtures.base_opts(Path.join(ctx.tmp_dir, "cli-cache"), arb_version: "1.2.3")}
  end

  defp row(status, name), do: Enum.find(status.clis, &(&1.name == name))

  test "reports pinned and latest-available versions, cache state, last bump and hold", %{
    opts: opts
  } do
    {:ok, _} = Settings.set_worker_cli_versions(%{"claude" => "2.1.308", "codex" => "0.164.0"})
    {:ok, _} = Settings.set_worker_cli_manual(["codex"])

    {:ok, _} =
      Settings.record_cli_version_event(%{
        kind: "cli_version_bumped",
        cli: "claude",
        from_version: "2.1.300",
        to_version: "2.1.308"
      })

    Fixtures.serve(Fixtures.claude_routes(["2.1.308"]))
    {:ok, _} = CliFetcher.ensure("claude", "2.1.308", opts)

    scheduler = %{
      enabled: true,
      checked_at: ~U[2026-10-26 03:00:00Z],
      latest: %{"claude" => "2.1.310", "codex" => "0.164.0"}
    }

    status = Status.build(opts ++ [scheduler_status: scheduler])

    assert status.hold == nil
    assert status.scheduler.enabled
    assert status.scheduler.checked_at == "2026-10-26T03:00:00Z"

    claude = row(status, "claude")
    assert %{pinned: "2.1.308", latest: "2.1.310", cached: true, manual: false} = claude
    assert %{from: "2.1.300", to: "2.1.308", at: at} = claude.last_bump
    assert is_binary(at)

    assert %{pinned: "0.164.0", latest: "0.164.0", cached: false, manual: true, last_bump: nil} =
             row(status, "codex")

    assert %{pinned: "1.2.3", latest: nil, cached: false} = row(status, "arb")
  end

  test "carries the hold token and an unpinned CLI", %{opts: opts} do
    {:ok, _} = Settings.set_worker_cli_set_hold("a1b2c3d4")

    status =
      Status.build(opts ++ [scheduler_status: %{enabled: false, checked_at: nil, latest: %{}}])

    assert status.hold == "a1b2c3d4"
    assert %{pinned: nil, latest: nil} = row(status, "claude")
    refute status.scheduler.enabled
  end

  test "is plain JSON-encodable data", %{opts: opts} do
    status =
      Status.build(opts ++ [scheduler_status: %{enabled: true, checked_at: nil, latest: %{}}])

    assert {:ok, _} = Jason.encode(status)
  end
end
