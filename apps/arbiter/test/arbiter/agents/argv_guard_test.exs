defmodule Arbiter.Agents.ArgvGuardTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.ArgvGuard

  test "max_arg_strlen is Linux's 131072" do
    assert ArgvGuard.max_arg_strlen() == 131_072
  end

  test "accepts argv at the limit" do
    assert :ok = ArgvGuard.check(["sh", String.duplicate("a", 131_072)])
  end

  test "refuses an oversize element with a descriptive error" do
    argv = ["sh", "-c", "x", String.duplicate("a", 131_073)]
    assert {:error, {:argv_element_too_large, 3, 131_073, 131_072}} = ArgvGuard.check(argv)
    assert ArgvGuard.message({:argv_element_too_large, 3, 131_073, 131_072}) =~ "MAX_ARG_STRLEN"
  end

  test "open_port raises the guard error before exec" do
    assert_raise RuntimeError, ~r/MAX_ARG_STRLEN/, fn ->
      Arbiter.Worker.ClaudeSession.open_port(%{
        exec: "/bin/sh",
        argv: ["sh", "-c", String.duplicate("a", 131_073)],
        cd: "."
      })
    end
  end
end
