defmodule Arbiter.Worker.TestRunTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.TestRun

  @moduletag :tmp_dir

  # A stand-in for `mix`: prints what it was given and replays a canned ExUnit
  # run from `$FAKE_MIX_OUTPUT`'s file, exiting with `$FAKE_MIX_STATUS`.
  setup %{tmp_dir: dir} do
    fake = Path.join(dir, "fake-mix")

    File.write!(fake, """
    #!/bin/sh
    shift
    echo "invoked in $(pwd | sed 's|.*/||'): $*" >> "$FAKE_MIX_CALLS"
    cat "$FAKE_MIX_OUTPUT"
    exit "$FAKE_MIX_STATUS"
    """)

    File.chmod!(fake, 0o755)

    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "apps/core/test/sub"))
    File.mkdir_p!(Path.join(repo, "apps/web/test"))
    File.mkdir_p!(Path.join(repo, "apps/core/lib"))
    File.write!(Path.join(repo, "apps/core/test/sub/a_test.exs"), "")
    File.write!(Path.join(repo, "apps/core/test/b_test.exs"), "")
    File.write!(Path.join(repo, "apps/web/test/c_test.exs"), "")
    File.write!(Path.join(repo, "apps/core/lib/thing.ex"), "")
    File.write!(Path.join(repo, "apps/core/test/thing_test.exs"), "")

    out = Path.join(dir, "out.txt")
    calls = Path.join(dir, "calls.txt")
    File.write!(calls, "")
    tmp = Path.join(dir, "tmp")
    File.mkdir_p!(tmp)

    exec = fn command, _seconds ->
      System.cmd("sh", ["-c", command],
        cd: repo,
        stderr_to_stdout: true,
        env: [
          {"FAKE_MIX_OUTPUT", out},
          {"FAKE_MIX_CALLS", calls},
          {"FAKE_MIX_STATUS", Process.get(:fake_status, "0")},
          {"TMPDIR", tmp}
        ]
      )
    end

    %{fake: fake, repo: repo, out: out, calls: calls, exec: exec, tmp: tmp}
  end

  defp runner(ctx, extra \\ %{}),
    do: Map.merge(%{exec: ctx.exec, worktree: ctx.repo, target: nil}, extra)

  defp calls(ctx), do: ctx.calls |> File.read!() |> String.split("\n", trim: true)

  describe "run/3" do
    test "a green run returns counts and the log path, not the output", ctx do
      File.write!(ctx.out, "Compiling 9 files\nwarning: noisy\n.....\n5 tests, 0 failures\n")

      assert {:ok, result} =
               TestRun.run(runner(ctx), %{paths: ["apps/core/test/b_test.exs"]}, mix: ctx.fake)

      assert result.report.status == :passed
      assert result.report.tests == 5
      refute result.text =~ "noisy"
      assert File.read!(result.log_path) =~ "warning: noisy"
      assert Path.dirname(result.log_path) == ctx.tmp
      assert calls(ctx) == ["invoked in core: test/b_test.exs"]
    end

    test "a red run returns the failure and keeps the full log on disk", ctx do
      Process.put(:fake_status, "2")

      File.write!(ctx.out, """
      Compiling 9 files

        1) test boom (Core.BTest)
           test/b_test.exs:4
           Assertion with == failed
           code:  assert 1 == 2
           left:  1
           right: 2
           stacktrace:
             test/b_test.exs:5: (test)

      1 test, 1 failure
      """)

      assert {:ok, result} =
               TestRun.run(runner(ctx), %{paths: ["apps/core/test/b_test.exs"]}, mix: ctx.fake)

      assert result.report.status == :failed
      assert result.text =~ "1) test boom (Core.BTest)"
      assert result.text =~ "right: 2"
      refute result.text =~ "Compiling"
      assert File.read!(result.log_path) =~ "Compiling 9 files"
    end

    test "groups paths by umbrella app and runs each from its own directory", ctx do
      File.write!(ctx.out, "2 tests, 0 failures\n")

      paths = ["apps/core/test/b_test.exs:4", "apps/web/test/c_test.exs", "apps/core/test/sub"]
      assert {:ok, result} = TestRun.run(runner(ctx), %{paths: paths}, mix: ctx.fake)

      assert result.report.tests == 4

      assert Enum.sort(calls(ctx)) == [
               "invoked in core: test/b_test.exs:4 test/sub",
               "invoked in web: test/c_test.exs"
             ]
    end

    test "resolves app-relative paths against the umbrella apps", ctx do
      File.write!(ctx.out, "1 test, 0 failures\n")

      assert {:ok, _} =
               TestRun.run(runner(ctx), %{paths: ["test/sub/a_test.exs"]}, mix: ctx.fake)

      assert calls(ctx) == ["invoked in core: test/sub/a_test.exs"]
    end

    test "refuses a path that does not exist instead of running everything", ctx do
      assert {:error, message} =
               TestRun.run(runner(ctx), %{paths: ["test/nope_test.exs"]}, mix: ctx.fake)

      assert message =~ "test/nope_test.exs"
      assert calls(ctx) == []
    end

    test "refuses option-looking and escaping paths", ctx do
      for bad <- ["--cover", "../outside_test.exs", "/etc/passwd", "a;rm -rf x", "a b_test.exs"] do
        assert {:error, _} = TestRun.run(runner(ctx), %{paths: [bad]}, mix: ctx.fake)
      end

      assert calls(ctx) == []
    end

    test "needs paths or changed", ctx do
      assert {:error, message} = TestRun.run(runner(ctx), %{paths: []}, mix: ctx.fake)
      assert message =~ "paths"
    end

    test "an exec that cannot run is an error", ctx do
      broken = %{exec: fn _, _ -> {:error, :not_sandboxed} end, worktree: ctx.repo, target: nil}

      assert {:error, message} =
               TestRun.run(broken, %{paths: ["apps/core/test/b_test.exs"]}, mix: ctx.fake)

      assert message =~ "not_sandboxed"
    end

    test "a killed run is a timeout", ctx do
      killed = %{
        exec: fn command, _ ->
          if command =~ "ARB_TEST_LOG",
            do: {"ARB_TEST_LOG=/x/y.log\n.....\n", 124},
            else: ctx.exec.(command, 1)
        end,
        worktree: ctx.repo,
        target: nil
      }

      assert {:ok, result} =
               TestRun.run(killed, %{paths: ["apps/core/test/b_test.exs"]}, mix: ctx.fake)

      assert result.report.status == :timeout
      assert result.log_path == "/x/y.log"
    end

    test "a node's tail-only output still yields the log path, from the closing marker", ctx do
      # NodeAgent.Exec keeps the last 256 KiB: the opening marker line is gone.
      tail_only = %{
        exec: fn command, _ ->
          if command =~ "ARB_TEST_LOG",
            do: {"...cut\n5 tests, 0 failures\n\nARB_TEST_LOG=/x/z.log\n", 0},
            else: ctx.exec.(command, 1)
        end,
        worktree: ctx.repo,
        target: nil
      }

      assert {:ok, result} =
               TestRun.run(tail_only, %{paths: ["apps/core/test/b_test.exs"]}, mix: ctx.fake)

      assert result.log_path == "/x/z.log"
      assert result.report.status == :passed
      assert result.report.tests == 5
      refute result.text =~ "ARB_TEST_LOG"
    end

    test "the command prints the log path again after the output", ctx do
      command = TestRun.test_command(["apps/core/test/b_test.exs"], ctx.fake)
      [_, after_cat] = String.split(command, ~s(cat "$LOG"\n), parts: 2)
      assert after_cat =~ ~s(ARB_TEST_LOG=%s)
    end
  end

  describe "run/3 with changed: true" do
    setup %{repo: repo} do
      git = fn args -> {_, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) end
      git.(["init", "-q", "-b", "main"])
      git.(["config", "user.email", "t@example.com"])
      git.(["config", "user.name", "t"])
      git.(["add", "-A"])
      git.(["commit", "-qm", "base"])
      git.(["checkout", "-qb", "work"])
      %{git: git}
    end

    test "maps committed, edited and untracked files to their tests", ctx do
      File.write!(ctx.out, "2 tests, 0 failures\n")
      File.write!(Path.join(ctx.repo, "apps/core/lib/thing.ex"), "# edited\n")
      File.write!(Path.join(ctx.repo, "apps/web/test/c_test.exs"), "# edited\n")
      File.write!(Path.join(ctx.repo, "apps/core/test/new_test.exs"), "")

      assert {:ok, result} =
               TestRun.run(runner(ctx, %{target: "main"}), %{changed: true}, mix: ctx.fake)

      assert result.report.status == :passed

      assert Enum.sort(calls(ctx)) == [
               "invoked in core: test/new_test.exs test/thing_test.exs",
               "invoked in web: test/c_test.exs"
             ]
    end

    test "reports when no test maps to the change", ctx do
      assert {:ok, result} =
               TestRun.run(runner(ctx, %{target: "main"}), %{changed: true}, mix: ctx.fake)

      assert result.text =~ "no tests"
      assert calls(ctx) == []
    end

    test "without a resolvable target it asks for paths", ctx do
      assert {:error, message} =
               TestRun.run(runner(ctx, %{target: "nope"}), %{changed: true}, mix: ctx.fake)

      assert message =~ "paths"
    end
  end
end
