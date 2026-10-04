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

    test "a fix pass nudge tells the worker the arbiter pushes and does not claim no PR was opened" do
      detail = {:exit, 1, "test failure"}
      prompt = PrepushCheck.nudge_prompt("bd-2", @meta, detail, :fix_pass)

      assert prompt =~ "bd-2"
      assert prompt =~ "bd-x/y"
      assert prompt =~ "nothing has been pushed"
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
