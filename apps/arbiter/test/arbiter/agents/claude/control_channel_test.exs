defmodule Arbiter.Agents.Claude.ControlChannelTest do
  @moduledoc """
  The stream-json control channel (bd-a2zrh0): `initialize` → account/token
  source, `get_usage` → usage, driven against a stubbed CLI that speaks the
  control protocol, plus every way the CLI can fail to.
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log
  @moduletag :tmp_dir

  alias Arbiter.Agents.Claude.ControlChannel

  alias Arbiter.Test.ClaudeControlStub

  @usage_body ClaudeControlStub.usage_body()

  setup %{tmp_dir: tmp_dir} do
    {:ok, stub: ClaudeControlStub.write!(tmp_dir)}
  end

  defp run(stub, mode, opts \\ []) do
    ControlChannel.run(
      Keyword.merge(
        [control_command: ["sh", stub, mode], timeout_ms: 5_000, env: []],
        opts
      )
    )
  end

  describe "run/1 against a CLI that speaks the control protocol" do
    test "reads the account (token source) from initialize", %{stub: stub} do
      assert {:ok, %{account: account, usage: :not_requested}} = run(stub, "ok")
      assert account["tokenSource"] == "claude.ai"
      assert ControlChannel.auth_state(account) == :authenticated
    end

    test "reads usage from get_usage when asked", %{stub: stub} do
      assert {:ok, %{account: %{"tokenSource" => "claude.ai"}, usage: {:ok, body}}} =
               run(stub, "ok", usage: true)

      assert body == @usage_body
    end

    test "reports an unauthenticated CLI from initialize", %{stub: stub} do
      assert {:ok, %{account: account}} = run(stub, "no_token")
      assert ControlChannel.auth_state(account) == :unauthenticated
    end

    test "an error answer to get_usage is returned, not raised", %{stub: stub} do
      assert {:ok, %{usage: {:error, msg}}} = run(stub, "usage_401", usage: true)
      assert msg =~ "401"
    end
  end

  describe "run/1 when the control request is not supported" do
    test "initialize answered with an unsupported error", %{stub: stub} do
      assert {:unsupported, {:control_error, msg}} = run(stub, "init_unsupported")
      assert msg =~ "Unsupported"
    end

    test "get_usage unsupported leaves the initialize result intact", %{stub: stub} do
      assert {:ok, %{account: %{"tokenSource" => "claude.ai"}, usage: {:unsupported, _}}} =
               run(stub, "no_usage", usage: true)
    end

    test "a CLI that exits without answering", %{stub: stub} do
      assert {:unsupported, {:exited, 3}} = run(stub, "exit")
    end

    test "a CLI that never answers initialize times out", %{stub: stub} do
      assert {:unsupported, :timeout} = run(stub, "init_hang", timeout_ms: 300)
    end

    test "get_usage that never answers times out without losing initialize", %{stub: stub} do
      assert {:ok, %{account: %{}, usage: {:unsupported, :timeout}}} =
               run(stub, "usage_hang", usage: true, timeout_ms: 300)
    end

    test "a missing executable is unsupported" do
      assert {:unsupported, {:executable_not_found, _}} =
               ControlChannel.run(
                 control_command: ["/nonexistent/claude-xyz"],
                 timeout_ms: 300,
                 env: []
               )
    end
  end

  describe "CLI version floor" do
    test "a CLI older than the floor is unsupported without spawning", %{stub: stub} do
      assert {:unsupported, {:cli_too_old, "1.0.5", _floor}} =
               run(stub, "ok", cli_version: "1.0.5")
    end

    test "a CLI at or above the floor is driven", %{stub: stub} do
      floor = ControlChannel.min_cli_version()
      assert {:ok, _} = run(stub, "ok", cli_version: floor)
    end

    test "parse_version/1 reads `claude --version` output" do
      assert ControlChannel.parse_version("2.1.272 (Claude Code)\n") == "2.1.272"
      assert ControlChannel.parse_version("garbage") == nil
    end

    test "version_at_least?/2 compares numerically, not lexically" do
      assert ControlChannel.version_at_least?("2.10.0", "2.9.0")
      refute ControlChannel.version_at_least?("2.1.9", "2.1.10")
    end
  end

  describe "a CLI that dies before reading stdin" do
    test "never takes the caller down (the port's :epipe exit is contained)" do
      # Without containment the linked port's :epipe exit signal kills a
      # non-trapping caller (CloudProbe, the credential watchdog) outright.
      results =
        for _ <- 1..40 do
          {pid, ref} =
            spawn_monitor(fn ->
              exit(
                {:result, ControlChannel.run(control_command: ["sh", "-c", "exit 3"], env: [])}
              )
            end)

          receive do
            {:DOWN, ^ref, :process, ^pid, reason} -> reason
          end
        end

      assert Enum.all?(results, &match?({:result, {:unsupported, _}}, &1)), inspect(results)
    end
  end

  describe "the process is reaped" do
    test "a hung CLI does not outlive the call", %{stub: stub, tmp_dir: tmp_dir} do
      # The stub `exec`s sleep, so the os_pid the channel kills is the sleeper.
      pidfile = Path.join(tmp_dir, "pid")
      script = Path.join(tmp_dir, "hang.sh")
      File.write!(script, "#!/bin/sh\necho $$ > #{pidfile}\nexec sleep 30\n")
      _ = stub

      assert {:unsupported, :timeout} =
               ControlChannel.run(control_command: ["sh", script], timeout_ms: 300, env: [])

      pid = pidfile |> File.read!() |> String.trim()
      {out, _} = System.cmd("sh", ["-c", "kill -0 #{pid} 2>/dev/null && echo alive || echo dead"])
      assert String.trim(out) == "dead"
    end
  end
end
