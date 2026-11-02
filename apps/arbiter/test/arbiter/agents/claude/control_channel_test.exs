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

  @usage_body %{
    "five_hour" => %{"utilization" => 42.0, "resets_at" => "2030-01-01T05:00:00Z"},
    "seven_day" => %{"utilization" => 10.0, "resets_at" => "2030-01-07T00:00:00Z"}
  }

  # A POSIX-sh stand-in for `claude -p --input-format stream-json …`. It reads
  # one JSON control_request per line from stdin and answers per `$1` (mode).
  @stub """
  #!/bin/sh
  MODE="$1"
  [ "$MODE" = "exit" ] && exit 3
  [ "$MODE" = "hang" ] && exec sleep 30
  while IFS= read -r line; do
    id=$(printf '%s' "$line" | sed -n 's/.*"request_id":"\\([^"]*\\)".*/\\1/p')
    sub=$(printf '%s' "$line" | sed -n 's/.*"subtype":"\\([^"]*\\)".*/\\1/p')
    printf '{"type":"system","subtype":"noise"}\\n'
    case "$sub" in
      initialize)
        case "$MODE" in
          init_unsupported)
            printf '{"type":"control_response","response":{"subtype":"error","request_id":"%s","error":"Unsupported control request subtype: initialize"}}\\n' "$id" ;;
          no_token)
            printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"account":{"tokenSource":"none"}}}}\\n' "$id" ;;
          init_hang)
            sleep 30 ;;
          *)
            printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"account":{"tokenSource":"claude.ai","subscriptionType":"max"}}}}\\n' "$id" ;;
        esac ;;
      get_usage)
        case "$MODE" in
          no_usage)
            printf '{"type":"control_response","response":{"subtype":"error","request_id":"%s","error":"Unsupported control request subtype: get_usage"}}\\n' "$id" ;;
          usage_401)
            printf '{"type":"control_response","response":{"subtype":"error","request_id":"%s","error":"Request failed with status code 401: invalid authentication credentials"}}\\n' "$id" ;;
          usage_hang)
            sleep 30 ;;
          *)
            printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":%s}}\\n' "$id" '#{Jason.encode!(@usage_body)}' ;;
        esac ;;
    esac
  done
  """

  setup %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "claude-stub.sh")
    File.write!(path, @stub)
    {:ok, stub: path}
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
