defmodule ArbiterCli.Cmd.RunCmdGuardTest do
  @moduledoc """
  `ArbiterCli.Cmd.Start.run_cmd/3` is the CLI's one spawn point for `mix`,
  `systemctl`, `lsof` and `kill`. A test that forgot its `:bd2_cmd_runner`
  stub once ran the real restart path from a worker: `lsof -ti tcp:4848` and
  `kill -TERM` hit the live coordinator's BEAM (bd-asawcq). Under `mix test`
  an unstubbed call must raise rather than exec anything.
  """
  use ExUnit.Case, async: true

  alias ArbiterCli.Cmd.Start

  test "an unstubbed run_cmd raises instead of executing" do
    Process.delete(:bd2_cmd_runner)

    marker = Path.join(System.tmp_dir!(), "run-cmd-guard-#{System.unique_integer([:positive])}")

    assert_raise RuntimeError, ~r/:bd2_cmd_runner/, fn ->
      Start.run_cmd("touch", [marker], [])
    end

    refute File.exists?(marker)
  end

  test "a stubbed run_cmd goes to the stub" do
    Process.put(:bd2_cmd_runner, fn cmd, args, _opts -> {"#{cmd} #{Enum.join(args, " ")}", 0} end)

    assert Start.run_cmd("lsof", ["-ti", "tcp:4848"], []) == {"lsof -ti tcp:4848", 0}
  end
end
