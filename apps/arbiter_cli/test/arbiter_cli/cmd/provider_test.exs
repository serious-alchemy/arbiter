defmodule ArbiterCli.Cmd.ProviderTest do
  @moduledoc "bd-5ef587: `arb provider pause|resume|list`."
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Provider

  @row %{
    "target" => "codex",
    "label" => "codex",
    "reason" => "jail escape",
    "by" => "api",
    "at" => "2026-09-30T12:00:00Z"
  }

  test "pause posts the ref, reason and stop flag" do
    stub_post("/api/providers/pause", %{"paused" => [@row], "stopped" => []}, 200)

    {out, _err, 0} =
      capture(fn -> Provider.run(["pause", "codex", "--reason", "jail escape"]) end)

    assert out =~ "Paused codex"
    assert out =~ "Running workers keep running"
  end

  test "pause --stop-running names what it stopped" do
    stub_post("/api/providers/pause", %{"paused" => [@row], "stopped" => ["bd-a"]}, 200)

    {out, _err, 0} = capture(fn -> Provider.run(["pause", "codex", "--stop-running"]) end)
    assert out =~ "Stopped running workers: bd-a"
  end

  test "resume" do
    stub_post("/api/providers/resume", %{"paused" => []}, 200)
    {out, _err, 0} = capture(fn -> Provider.run(["resume", "codex"]) end)
    assert out =~ "Resumed codex"
  end

  test "list shows who, when and why" do
    stub_get("/api/providers/paused", %{"paused" => [@row]})
    {out, _err, 0} = capture(fn -> Provider.run(["list"]) end)
    assert out =~ "jail escape"
    assert out =~ "by api"
    assert out =~ "2026-09-30T12:00:00Z"
  end

  test "list with nothing paused" do
    stub_get("/api/providers/paused", %{"paused" => []})
    {out, _err, 0} = capture(fn -> Provider.run(["list"]) end)
    assert out =~ "No providers paused"
  end
end
