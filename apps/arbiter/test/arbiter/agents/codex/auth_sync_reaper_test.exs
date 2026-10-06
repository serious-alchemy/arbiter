defmodule Arbiter.Agents.Codex.AuthSync.ReaperTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Codex.AuthSync.Reaper

  @moduletag :tmp_dir
  @moduletag :capture_log

  defp auth(refresh, last_refresh) do
    Jason.encode!(%{
      "tokens" => %{"refresh_token" => refresh, "access_token" => "a", "account_id" => "acct"},
      "last_refresh" => last_refresh
    })
  end

  setup %{tmp_dir: dir} do
    source = Path.join(dir, "auth.json")
    run = Path.join(dir, "run-auth.json")
    File.write!(source, auth("rt-0", "2026-10-01T00:00:00Z"))
    File.write!(run, auth("rt-0", "2026-10-01T00:00:00Z"))
    reaper = start_supervised!({Reaper, name: nil})
    %{source: source, run: run, reaper: reaper}
  end

  defp owner do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  test "a rotation is persisted when the owner dies without any cleanup", ctx do
    pid = owner()
    :ok = Reaper.track(pid, ctx.source, ctx.run, ctx.reaper)
    File.write!(ctx.run, auth("rt-1", "2026-10-02T00:00:00Z"))

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    # The reaper handles its own DOWN message; a call after it is ordered behind it.
    _ = :sys.get_state(ctx.reaper)

    assert Jason.decode!(File.read!(ctx.source))["tokens"]["refresh_token"] == "rt-1"
  end

  test "flush/2 persists synchronously, ahead of the run dir being removed", ctx do
    pid = owner()
    :ok = Reaper.track(pid, ctx.source, ctx.run, ctx.reaper)
    File.write!(ctx.run, auth("rt-1", "2026-10-02T00:00:00Z"))

    assert :ok = Reaper.flush(pid, ctx.reaper)
    assert Jason.decode!(File.read!(ctx.source))["tokens"]["refresh_token"] == "rt-1"
  end

  test "flush/2 for an unknown owner, or with no reaper running, is a no-op", ctx do
    assert :ok = Reaper.flush(owner(), ctx.reaper)
    assert :ok = Reaper.flush(owner(), :no_such_reaper)
  end

  test "every run an owner has is flushed", ctx do
    pid = owner()
    other_run = ctx.run <> ".2"
    File.write!(other_run, auth("rt-5", "2026-10-05T00:00:00Z"))
    :ok = Reaper.track(pid, ctx.source, ctx.run, ctx.reaper)
    :ok = Reaper.track(pid, ctx.source, other_run, ctx.reaper)
    File.write!(ctx.run, auth("rt-1", "2026-10-02T00:00:00Z"))

    :ok = Reaper.flush(pid, ctx.reaper)
    assert Jason.decode!(File.read!(ctx.source))["tokens"]["refresh_token"] == "rt-5"
  end
end
