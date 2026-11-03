defmodule Arbiter.Agents.ClaudeControlPreflightTest do
  @moduledoc """
  bd-a2zrh0: the Claude pre-flight reads auth state from the control channel's
  `initialize` and validates it with `get_usage`, and falls back to the
  `claude --print ping` probe whenever the channel cannot answer.
  """
  use ExUnit.Case, async: false

  @moduletag :capture_log
  @moduletag :tmp_dir

  alias Arbiter.Agents.Claude
  alias Arbiter.Agents.Claude.ControlChannel
  alias Arbiter.Agents.Preflight
  alias Arbiter.Test.ClaudeControlStub
  alias Arbiter.Worker.StopReason

  setup %{tmp_dir: tmp_dir} do
    stub = ClaudeControlStub.write!(tmp_dir)

    # A fake `claude` on PATH: the legacy `--print ping` probe. It leaves a
    # marker so a test can tell whether the ping path actually ran.
    marker = Path.join(tmp_dir, "ping-ran")
    bin_dir = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin_dir)
    fake = Path.join(bin_dir, "claude")
    File.write!(fake, "#!/bin/sh\n: > #{marker}\necho pong\n")
    File.chmod!(fake, 0o755)

    prev_env = for v <- ~w(PATH ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN), do: {v, System.get_env(v)}
    prev_cfg = Application.get_env(:arbiter, ControlChannel)
    Application.put_env(:arbiter, ControlChannel, enabled: true)
    System.put_env("PATH", bin_dir <> ":" <> System.get_env("PATH", ""))
    System.put_env("ANTHROPIC_API_KEY", "sk-ant-test")

    on_exit(fn ->
      Enum.each(prev_env, fn
        {v, nil} -> System.delete_env(v)
        {v, val} -> System.put_env(v, val)
      end)

      if prev_cfg,
        do: Application.put_env(:arbiter, ControlChannel, prev_cfg),
        else: Application.delete_env(:arbiter, ControlChannel)
    end)

    {:ok, stub: stub, marker: marker}
  end

  defp opts(stub, mode, extra \\ []) do
    Keyword.merge([control_command: ["sh", stub, mode], timeout_ms: 2_000], extra)
  end

  describe "Claude.auth_probe/1 over the control channel" do
    test "initialize + get_usage success is an authenticated pre-flight", %{stub: stub} do
      assert Claude.auth_probe(opts(stub, "ok")) == :ok
    end

    test "Preflight.check consumes it and never runs the ping", %{stub: stub, marker: marker} do
      assert Preflight.check(Claude, opts(stub, "ok")) == :ok
      refute File.exists?(marker)
    end

    test "initialize reporting no token is auth_expired", %{stub: stub, marker: marker} do
      assert {:error, %StopReason{category: :auth_expired}} =
               Preflight.check(Claude, opts(stub, "no_token"))

      refute File.exists?(marker)
    end

    test "get_usage failing with a 401 is auth_expired", %{stub: stub, marker: marker} do
      assert {:error, %StopReason{category: :auth_expired}} =
               Preflight.check(Claude, opts(stub, "usage_401"))

      refute File.exists?(marker)
    end
  end

  describe "fallback to the ping pre-flight" do
    for mode <- ~w(init_unsupported init_hang no_usage usage_hang usage_429 exit) do
      test "control channel answering #{mode} declines and the ping runs",
           %{stub: stub, marker: marker} do
        mode = unquote(mode)
        o = opts(stub, mode, timeout_ms: 300)

        assert Claude.auth_probe(o) == :skipped
        assert Preflight.check(Claude, o) == :ok
        assert File.exists?(marker)
      end
    end

    test "an old CLI declines and the ping runs", %{stub: stub, marker: marker} do
      o = opts(stub, "ok", cli_version: "1.0.0")
      assert Claude.auth_probe(o) == :skipped
      assert Preflight.check(Claude, o) == :ok
      assert File.exists?(marker)
    end

    test "a disabled channel declines and the ping runs", %{stub: stub, marker: marker} do
      Application.put_env(:arbiter, ControlChannel, enabled: false)
      assert Preflight.check(Claude, opts(stub, "ok")) == :ok
      assert File.exists?(marker)
    end
  end
end
