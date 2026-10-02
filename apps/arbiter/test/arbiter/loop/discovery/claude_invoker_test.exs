defmodule Arbiter.Loop.Discovery.ClaudeInvokerTest do
  @moduledoc """
  The per-call bounds `Arbiter.Loop.Discovery.ClaudeInvoker` passes to the CLI
  (bd-avt4lt): a dollar cap, an output ceiling and a model, each only when a
  caller asks, so the discovery pass's own call is unchanged.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Loop.Discovery.ClaudeInvoker

  defp flag(args, name) do
    case Enum.drop_while(args, &(&1 != name)) do
      [^name, value | _] -> value
      _ -> nil
    end
  end

  describe "args/1" do
    test "is the tool-less print-mode turn, with no cap or model unless asked" do
      args = ClaudeInvoker.args([])

      assert ["--print" | _] = args
      assert flag(args, "--tools") == ""
      assert flag(args, "--max-budget-usd") == nil
    end

    test "passes a per-call dollar cap to the CLI" do
      assert ClaudeInvoker.args(max_budget_usd: 0.25) |> flag("--max-budget-usd") == "0.25"
      assert ClaudeInvoker.args(max_budget_usd: 2) |> flag("--max-budget-usd") == "2.0"
    end

    test "uses the caller's model" do
      assert ClaudeInvoker.args(model: "claude-sonnet-5-5") |> flag("--model") ==
               "claude-sonnet-5-5"
    end
  end

  describe "extra_env/1" do
    test "caps output tokens through the CLI's own variable, only when asked" do
      assert ClaudeInvoker.extra_env(max_output_tokens: 2_000) ==
               [{"CLAUDE_CODE_MAX_OUTPUT_TOKENS", "2000"}]

      assert ClaudeInvoker.extra_env([]) == []
    end
  end

  describe "parse_stream/1" do
    test "reports the result's subtype, so a budget stop is visible" do
      stream =
        ~s({"type":"result","subtype":"error_max_budget_usd","is_error":true,) <>
          ~s("total_cost_usd":0.3,"usage":{}}\n)

      assert {:ok, "", %{subtype: "error_max_budget_usd", is_error: true, cost_usd: 0.3}} =
               ClaudeInvoker.parse_stream(stream)
    end

    # What the real CLI emits with no credential: a "success" subtype that is
    # an error, with the error text where the reply would be.
    test "reports is_error, which a failed call can carry under a success subtype" do
      stream =
        ~s({"type":"result","subtype":"success","is_error":true,) <>
          ~s("result":"Not logged in · Please run /login","total_cost_usd":0}\n)

      assert {:ok, "Not logged in · Please run /login", %{subtype: "success", is_error: true}} =
               ClaudeInvoker.parse_stream(stream)
    end
  end

  describe "invoke/2" do
    test "a non-zero exit whose output contains a result event with is_error: true and total_cost_usd > 0 is returned as ok so it can be metered" do
      # Create a dummy claude script that emits a budget error and exits 1.
      dir =
        Path.join(System.tmp_dir!(), "claude_invoker_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)

      dummy = Path.join(dir, "claude")

      script = """
      #!/bin/sh
      echo '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":0.3,"usage":{}}'
      exit 1
      """

      File.write!(dummy, script)
      File.chmod!(dummy, 0o755)

      original_path = System.get_env("PATH")
      System.put_env("PATH", "#{dir}:#{original_path}")

      try do
        assert {:ok, "", usage} = ClaudeInvoker.invoke("test prompt", [])
        assert usage.is_error == true
        assert usage.cost_usd == 0.3
        assert usage.subtype == "error_max_budget_usd"
      after
        System.put_env("PATH", original_path)
        File.rm_rf!(dir)
      end
    end
  end
end
