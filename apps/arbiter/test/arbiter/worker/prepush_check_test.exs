defmodule Arbiter.Worker.PrepushCheckTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.PrepushCheck

  defp ws(worker), do: %{config: %{"worker" => worker}}

  defp run(command, dir, opts \\ []) do
    spec = %{
      command: command,
      timeout_seconds: Keyword.get(opts, :timeout_seconds, 30),
      on_timeout: :proceed
    }

    PrepushCheck.run(spec, dir)
  end

  describe "resolve/2" do
    test "nil when unset at both levels, blank, or not a string" do
      assert PrepushCheck.resolve(nil, "arbiter") == nil
      assert PrepushCheck.resolve(%{config: %{}}, "arbiter") == nil
      assert PrepushCheck.resolve(%{config: nil}, "arbiter") == nil
      assert PrepushCheck.resolve(ws(%{"prepush_check" => "   "}), "arbiter") == nil
      assert PrepushCheck.resolve(ws(%{"prepush_check" => ["mix test"]}), "arbiter") == nil

      assert PrepushCheck.resolve(
               ws(%{"repos" => %{"other" => %{"prepush_check" => "true"}}}),
               "arbiter"
             ) == nil
    end

    test "the workspace-level command applies to every repo, with the default timeout" do
      assert %{command: "mix precommit", timeout_seconds: 1200, on_timeout: :proceed} =
               PrepushCheck.resolve(ws(%{"prepush_check" => "mix precommit"}), "arbiter")

      assert %{command: "mix precommit"} =
               PrepushCheck.resolve(ws(%{"prepush_check" => "mix precommit"}), nil)
    end

    test "a per-repo command wins over the workspace-level one" do
      workspace =
        ws(%{
          "prepush_check" => "make lint",
          "repos" => %{"arbiter" => %{"prepush_check" => "mix precommit && mix audit"}}
        })

      assert %{command: "mix precommit && mix audit"} = PrepushCheck.resolve(workspace, "arbiter")
      assert %{command: "make lint"} = PrepushCheck.resolve(workspace, "vstim")
    end

    test "matches the repo key the way repo_paths keys match (owner/name -> name)" do
      workspace = ws(%{"repos" => %{"arbiter" => %{"prepush_check" => "true"}}})

      assert %{command: "true"} = PrepushCheck.resolve(workspace, "ryan/arbiter")
    end

    test "timeout and on_timeout are configurable, per repo too" do
      workspace =
        ws(%{
          "prepush_check" => "true",
          "prepush_check_timeout_seconds" => 60,
          "repos" => %{"arbiter" => %{"prepush_check_on_timeout" => "fail"}}
        })

      assert %{timeout_seconds: 60, on_timeout: :fail} =
               PrepushCheck.resolve(workspace, "arbiter")

      assert %{timeout_seconds: 60, on_timeout: :proceed} =
               PrepushCheck.resolve(workspace, "other")
    end

    test "an invalid timeout or on_timeout reads as the default" do
      workspace =
        ws(%{
          "prepush_check" => "true",
          "prepush_check_timeout_seconds" => -5,
          "prepush_check_on_timeout" => "explode"
        })

      assert %{timeout_seconds: 1200, on_timeout: :proceed} =
               PrepushCheck.resolve(workspace, "arbiter")
    end
  end

  describe "run/2" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      root = Path.join(dir, "worker-tmp")
      File.mkdir_p!(root)
      previous = Application.get_env(:arbiter, :worker_tmp_root)
      Application.put_env(:arbiter, :worker_tmp_root, root)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:arbiter, :worker_tmp_root, previous),
          else: Application.delete_env(:arbiter, :worker_tmp_root)
      end)

      :ok
    end

    test "a zero exit is :ok and the command runs in the worktree", %{tmp_dir: dir} do
      assert :ok = run("test -f marker && exit 0", dir_with(dir, "marker"))
    end

    test "a non-zero exit returns the status and the combined output", %{tmp_dir: dir} do
      assert {:failed, 3, output} = run("echo out; echo err 1>&2; exit 3", dir)
      assert output =~ "out"
      assert output =~ "err"
    end

    test "output is bounded to its tail", %{tmp_dir: dir} do
      assert {:failed, 1, output} =
               run("i=0; while [ $i -lt 3000 ]; do echo line-$i; i=$((i+1)); done; exit 1", dir)

      assert output =~ "line-2999"
      refute output =~ "line-0\n"
      assert byte_size(output) <= 16_500
    end

    test "a command that outlives its timeout is :timeout, and is killed", %{tmp_dir: dir} do
      sentinel = Path.join(dir, "survived")

      assert {:timeout, output} =
               run("echo started; sleep 5; touch #{sentinel}", dir, timeout_seconds: 1)

      assert output =~ "started"
      refute File.exists?(sentinel)
      Process.sleep(100)
      refute File.exists?(sentinel)
    end

    test "a worktree that is not a directory is an infra error, not a failure" do
      assert {:error, {:no_worktree, _}} = run("true", "/nonexistent/prepush/dir")
    end

    test "the check runs on the repo-pinned toolchain first on PATH (bd-3fnqi8)",
         %{tmp_dir: dir} do
      root = Path.join(dir, "installs")
      bin = Path.join([root, "elixir", "1.20.4-otp-29", "bin"])
      File.mkdir_p!(bin)

      File.write!(Path.join(bin, "elixir"), """
      #!/bin/sh
      printf 'Erlang/OTP 29 [erts]\\n\\nElixir 1.20.4 (compiled with Erlang/OTP 29)\\n'
      """)

      File.chmod!(Path.join(bin, "elixir"), 0o755)
      wt = Path.join(dir, "wt")
      File.mkdir_p!(wt)
      File.write!(Path.join(wt, ".tool-versions"), "elixir 1.20.4-otp-29\n")
      Application.put_env(:arbiter, :worker_toolchain_roots, [root])
      on_exit(fn -> Application.delete_env(:arbiter, :worker_toolchain_roots) end)

      assert {:failed, 1, output} = run("command -v elixir; elixir --version; exit 1", wt)
      assert output =~ bin
    end

    test "a pinned toolchain that cannot be provided runs nothing and is an error (bd-3fnqi8)",
         %{tmp_dir: dir} do
      wt = Path.join(dir, "wt")
      File.mkdir_p!(wt)
      File.write!(Path.join(wt, ".tool-versions"), "elixir 1.20.4-otp-29\n")
      Application.put_env(:arbiter, :worker_toolchain_roots, [Path.join(dir, "empty")])
      Application.put_env(:arbiter, :worker_toolchain_provision, false)

      on_exit(fn ->
        Application.delete_env(:arbiter, :worker_toolchain_roots)
        Application.delete_env(:arbiter, :worker_toolchain_provision)
      end)

      marker = Path.join(dir, "ran")

      assert {:error, {:toolchain_unavailable, message}} = run("touch #{marker}", wt)
      assert message =~ "elixir 1.20.4-otp-29"
      refute File.exists?(marker)
    end

    test "the sanitised env keeps server secrets out of the check", %{tmp_dir: dir} do
      System.put_env("ARBITER_CLOAK_KEY", "super-secret")
      on_exit(fn -> System.delete_env("ARBITER_CLOAK_KEY") end)

      assert {:failed, 1, output} =
               run("test -z \"$ARBITER_CLOAK_KEY\" && echo clean; exit 1", dir)

      assert output =~ "clean"
    end

    test "a private TMPDIR is provided and removed afterwards", %{tmp_dir: dir} do
      assert {:failed, 1, output} = run("echo \"tmp=$TMPDIR\"; exit 1", dir)
      [_, tmp] = Regex.run(~r/tmp=(\S+)/, output)
      assert tmp != System.tmp_dir!()
      refute File.exists?(tmp)
    end
  end

  describe "ExUnit failure digest" do
    defp exunit_output(noise_bytes) do
      """
      Compiling 3 files (.ex)
      ..

        1) test deterministic thing (Arbiter.FooTest)
           test/arbiter/foo_test.exs:12
           Assertion with == failed
           code:  assert foo() == 2
           left:  1
           right: 2

        2) test second thing (Arbiter.FooTest)
           test/arbiter/foo_test.exs:30
           ** (RuntimeError) boom

      Finished in 3.2 seconds (1.0s async, 2.2s sync)
      789 tests, 2 failures

      Randomized with seed 1
      """ <>
        String.duplicate("SANDBOX CONNECTION KILLED: teardown report\n", div(noise_bytes, 44))
    end

    defp run_exec(output, status) do
      spec = %{
        steps: [%{name: "tests", cmd: "mix test", timeout_s: 30, scope: :all}],
        timeout_seconds: 60,
        on_timeout: :proceed
      }

      dir = Path.join(System.tmp_dir!(), "pc-digest-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      PrepushCheck.run_steps(spec, dir, exec: fn _cmd, _s -> {output, status} end)
    end

    test "failing test names and assertions survive a huge post-summary dump" do
      output = exunit_output(40_000)
      assert %{steps: [step], result: {:failed, 2, stored}} = run_exec(output, 2)

      assert step.output =~ "test deterministic thing (Arbiter.FooTest)"
      assert step.output =~ "left:  1"
      assert step.output =~ "** (RuntimeError) boom"
      assert step.output =~ "789 tests, 2 failures"
      assert stored == step.output
      assert step.full_output == output
    end

    test "fit/2 keeps the failure section whole when bounding" do
      {:failed, 2, stored} = run_exec(exunit_output(40_000), 2).result
      fitted = PrepushCheck.fit(stored, 3_000)
      assert byte_size(fitted) <= 3_200
      assert fitted =~ "test deterministic thing"
    end

    test "non-test output is the plain tail and passing steps store nothing" do
      assert %{steps: [step]} = run_exec("credo: 3 issues\n", 1)
      assert step.output == "credo: 3 issues"
      assert step.full_output == "credo: 3 issues\n"
      assert %{steps: [ok]} = run_exec("fine\n", 0)
      assert ok.output == ""
      assert ok.full_output == "fine\n"
    end

    test "the send-back lists failing test names before the tail" do
      %{steps: [step]} = run_exec(exunit_output(40_000), 2)
      meta = %{prepush_steps: [step], prepush_spec: %{command: "x"}}
      prompt = PrepushCheck.nudge_prompt("bd-1", meta, {:exit, 2, step.output})
      assert prompt =~ "test deterministic thing"
      assert prompt =~ "left:  1"
    end
  end

  describe "tail/2" do
    test "keeps the end of an oversized string on a line boundary" do
      text = Enum.map_join(1..100, "\n", &"line-#{&1}")
      tail = PrepushCheck.tail(text, 60)
      assert byte_size(tail) <= 60 + 80
      assert tail =~ "line-100"
      assert tail =~ "truncated"
    end

    test "returns short strings untouched" do
      assert PrepushCheck.tail("abc", 60) == "abc"
    end
  end

  describe "nudge_prompt and failure_blurb" do
    @meta %{branch: "bd-x/y", prepush_spec: %{command: "mix precommit && mix audit"}}

    test "the send-back carries the command, the exit status and the output" do
      detail = {:exit, 2, "** (Mix) credo found 3 issues"}
      prompt = PrepushCheck.nudge_prompt("bd-1", @meta, detail)

      assert prompt =~ "bd-1"
      assert prompt =~ "bd-x/y"
      assert prompt =~ "mix precommit && mix audit"
      assert prompt =~ "exited with status 2"
      assert prompt =~ "credo found 3 issues"
      assert prompt =~ "has been pushed and no PR has been opened"
    end

    test "the send-back lists the tests for the changed files" do
      dir = Path.join(System.tmp_dir!(), "pc-hint-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      File.mkdir_p!(Path.join(dir, "lib"))
      File.mkdir_p!(Path.join(dir, "test"))
      File.write!(Path.join(dir, "lib/foo.ex"), "")
      File.write!(Path.join(dir, "test/foo_test.exs"), "")
      git = fn args -> {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) end
      git.(["init", "-q", "-b", "main"])

      git.([
        "-c",
        "user.email=a@b",
        "-c",
        "user.name=a",
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        "base"
      ])

      git.(["checkout", "-q", "-b", "work"])
      git.(["add", "-A"])
      git.(["-c", "user.email=a@b", "-c", "user.name=a", "commit", "-q", "-m", "change"])

      meta = Map.merge(@meta, %{worktree_path: dir, target_branch: "main"})
      prompt = PrepushCheck.nudge_prompt("bd-4", meta, {:exit, 1, "boom"})

      assert prompt =~ "Tests for your changed files"
      refute prompt =~ "scripts/pre-push-tests.sh"
      assert prompt =~ "test/foo_test.exs"

      File.mkdir_p!(Path.join(dir, "scripts"))
      File.write!(Path.join(dir, "scripts/pre-push-tests.sh"), "")
      prompt = PrepushCheck.nudge_prompt("bd-4", meta, {:exit, 1, "boom"})
      assert prompt =~ "scripts/pre-push-tests.sh test/foo_test.exs"
    end

    test "no test hint without a worktree" do
      refute PrepushCheck.nudge_prompt("bd-5", @meta, {:exit, 1, "boom"}) =~
               "Tests for your changed"
    end

    test "a fix pass nudge tells the worker the arbiter pushes and does not claim no PR was opened" do
      detail = {:exit, 1, "test failure"}
      prompt = PrepushCheck.nudge_prompt("bd-2", @meta, detail, :fix_pass)

      assert prompt =~ "bd-2"
      assert prompt =~ "bd-x/y"
      assert prompt =~ "nothing\nhas been pushed"
      refute prompt =~ "no PR has been opened"
      assert prompt =~ "the arbiter pushes to `bd-x/y` for you"
    end

    test "nudge_prompt and failure_blurb fall back to fix_pass_branch when branch is nil" do
      meta = %{fix_pass_branch: "fix/pass-branch", prepush_spec: %{command: "mix test"}}
      detail = {:exit, 1, "failed"}

      prompt = PrepushCheck.nudge_prompt("bd-3", meta, detail, :fix_pass)
      assert prompt =~ "fix/pass-branch"
      assert prompt =~ "the arbiter pushes to `fix/pass-branch` for you"

      blurb = PrepushCheck.failure_blurb(Map.put(meta, :prepush_detail, detail))
      assert blurb =~ "fix/pass-branch"
    end

    test "a timeout-as-failure says so" do
      detail = {:timeout, 90, "dialyzer: building PLT"}
      prompt = PrepushCheck.nudge_prompt("bd-1", @meta, detail)

      assert prompt =~ "timed out after 90s"
      assert prompt =~ "building PLT"
    end

    test "the escalation blurb names the command and a bounded slice of the output" do
      big = String.duplicate("x", 50_000) <> "\nTAIL-MARKER"
      blurb = PrepushCheck.failure_blurb(Map.put(@meta, :prepush_detail, {:exit, 1, big}))

      assert blurb =~ "mix precommit && mix audit"
      assert blurb =~ "TAIL-MARKER"
      assert blurb =~ "NOT pushed"
      assert byte_size(blurb) < 6_000
    end
  end

  defp dir_with(dir, file) do
    File.write!(Path.join(dir, file), "x")
    dir
  end
end
