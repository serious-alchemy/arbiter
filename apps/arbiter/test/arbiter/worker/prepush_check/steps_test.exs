defmodule Arbiter.Worker.PrepushCheck.StepsTest do
  @moduledoc """
  bd-8wdrql: the multi-step recipe (`worker.repos.<repo>.pre_push_checks`) —
  resolution, the total time budget, touched-file scoping, and the per-step
  results `run_steps/3` returns for the run's step rows.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Worker.PrepushCheck

  defp ws(worker), do: %{config: %{"worker" => worker}}

  defp step(name, cmd, extra \\ %{}), do: Map.merge(%{"name" => name, "cmd" => cmd}, extra)

  describe "resolve/2 with pre_push_checks" do
    test "builds steps with defaults: 120s timeout, scope all, 180s budget" do
      spec =
        PrepushCheck.resolve(
          ws(%{
            "pre_push_checks" => [
              step("fmt", "mix format --check-formatted", %{"timeout_s" => 60}),
              step("credo", "mix credo {elixir_files}", %{"scope" => "touched"})
            ]
          }),
          "arbiter"
        )

      assert [
               %{name: "fmt", cmd: "mix format --check-formatted", timeout_s: 60, scope: :all},
               %{name: "credo", cmd: "mix credo {elixir_files}", timeout_s: 120, scope: :touched}
             ] = spec.steps

      assert spec.budget_seconds == 180
      assert spec.timeout_seconds == 180
      assert spec.on_timeout == :proceed
      assert spec.command =~ "mix format --check-formatted"
      assert spec.command =~ "mix credo"
    end

    test "the total budget, the timeout policy and the attempt cap are configurable" do
      spec =
        PrepushCheck.resolve(
          ws(%{
            "pre_push_checks" => [step("a", "true")],
            "pre_push_budget_seconds" => 45,
            "prepush_check_on_timeout" => "fail",
            "pre_push_max_attempts" => 4
          }),
          "arbiter"
        )

      assert %{budget_seconds: 45, on_timeout: :fail, max_attempts: 4} = spec
    end

    test "the repo entry overrides the workspace-level recipe" do
      workspace =
        ws(%{
          "pre_push_checks" => [step("global", "true")],
          "repos" => %{"arbiter" => %{"pre_push_checks" => [step("repo", "true")]}}
        })

      assert %{steps: [%{name: "repo"}]} = PrepushCheck.resolve(workspace, "arbiter")
      assert %{steps: [%{name: "global"}]} = PrepushCheck.resolve(workspace, "other")
    end

    test "the \"arbiter\" preset is the default recipe" do
      spec = PrepushCheck.resolve(ws(%{"pre_push_checks" => "arbiter"}), "arbiter")

      names = Enum.map(spec.steps, & &1.name)
      assert names == ~w(format compile credo doc_citations tests)

      by_name = Map.new(spec.steps, &{&1.name, &1})
      assert by_name["format"].cmd =~ "mix format --check-formatted"
      assert by_name["compile"].cmd =~ "mix compile --warnings-as-errors"
      assert by_name["credo"].cmd =~ "mix credo --strict {credo_files}"
      assert by_name["credo"].scope == :touched
      assert by_name["doc_citations"].cmd =~ "review_coverage_design_test"
      assert by_name["tests"].cmd =~ "{test_files}"
      assert by_name["tests"].scope == :touched
    end

    test "invalid entries are dropped; nothing valid means no check" do
      spec =
        PrepushCheck.resolve(
          ws(%{
            "pre_push_checks" => [
              "just a string",
              %{"name" => "nocmd"},
              step("blank", "  "),
              step("ok", "true", %{"scope" => "bogus", "timeout_s" => -3})
            ]
          }),
          "arbiter"
        )

      assert [%{name: "ok", scope: :all, timeout_s: 120}] = spec.steps

      assert PrepushCheck.resolve(ws(%{"pre_push_checks" => []}), "arbiter") == nil
      assert PrepushCheck.resolve(ws(%{"pre_push_checks" => "nonsense"}), "arbiter") == nil
    end

    test "pre_push_checks wins over the single-command prepush_check" do
      spec =
        PrepushCheck.resolve(
          ws(%{"prepush_check" => "make lint", "pre_push_checks" => [step("a", "true")]}),
          "arbiter"
        )

      assert [%{name: "a"}] = spec.steps
    end

    test "the legacy single command is one step with its own timeout as the budget" do
      spec =
        PrepushCheck.resolve(
          ws(%{"prepush_check" => "make lint", "prepush_check_timeout_seconds" => 90}),
          "arbiter"
        )

      assert [%{name: "prepush_check", cmd: "make lint", timeout_s: 90, scope: :all}] = spec.steps
      assert spec.budget_seconds == 90
    end
  end

  describe "run_steps/3" do
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

      repo = Path.join(dir, "repo")
      File.mkdir_p!(repo)
      git(repo, ["init", "-q", "-b", "main"])
      git(repo, ["config", "user.email", "t@example.com"])
      git(repo, ["config", "user.name", "T"])
      git(repo, ["config", "commit.gpgsign", "false"])
      File.mkdir_p!(Path.join(repo, "lib"))
      File.mkdir_p!(Path.join(repo, "test"))
      File.write!(Path.join(repo, "lib/a.ex"), "a\n")
      File.write!(Path.join(repo, "test/a_test.exs"), "t\n")
      git(repo, ["add", "-A"])
      git(repo, ["commit", "-q", "-m", "seed"])
      git(repo, ["checkout", "-q", "-b", "work"])
      %{repo: repo}
    end

    defp git(dir, args),
      do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

    defp commit_change(repo, path) do
      File.write!(Path.join(repo, path), "changed\n")
      git(repo, ["add", "-A"])
      git(repo, ["commit", "-q", "-m", "work"])
    end

    defp spec(steps, extra \\ %{}) do
      resolved =
        PrepushCheck.resolve(ws(Map.merge(%{"pre_push_checks" => steps}, extra)), "arbiter")

      resolved
    end

    test "all green: :ok, one passed result per step with timing", %{repo: repo} do
      spec = spec([step("one", "true"), step("two", "echo hi")])

      assert %{result: :ok, steps: [one, two]} = PrepushCheck.run_steps(spec, repo)
      assert %{name: "one", status: :passed, exit_status: 0, cmd: "true"} = one
      assert %{name: "two", status: :passed} = two
      assert is_integer(one.duration_ms) and one.duration_ms >= 0
    end

    test "a failing step is reported with its output, and the remaining steps still run", %{
      repo: repo
    } do
      spec =
        spec([
          step("bad", "echo format-error; exit 1"),
          step("good", "true"),
          step("bad2", "echo credo-error; exit 2")
        ])

      assert %{result: {:failed, 1, output}, steps: [bad, good, bad2]} =
               PrepushCheck.run_steps(spec, repo)

      assert output =~ "format-error"
      assert %{status: :failed, exit_status: 1, output: o1} = bad
      assert o1 =~ "format-error"
      assert %{status: :passed, output: ""} = good
      assert %{status: :failed, exit_status: 2} = bad2
    end

    test "a step that outlives its timeout is :timeout and is killed", %{repo: repo, tmp_dir: dir} do
      sentinel = Path.join(dir, "survived")
      spec = spec([step("slow", "echo started; sleep 5; touch #{sentinel}", %{"timeout_s" => 1})])

      assert %{result: {:timeout, out}, steps: [%{status: :timeout}]} =
               PrepushCheck.run_steps(spec, repo)

      assert out =~ "started"
      refute File.exists?(sentinel)
    end

    test "the total budget caps the recipe: later steps are skipped, not run", %{
      repo: repo,
      tmp_dir: dir
    } do
      marker = Path.join(dir, "ran-third")

      spec =
        spec(
          [
            step("slow", "sleep 5", %{"timeout_s" => 60}),
            step("never", "touch #{marker}")
          ],
          %{"pre_push_budget_seconds" => 1}
        )

      assert %{result: {:timeout, _}, steps: [slow, never]} = PrepushCheck.run_steps(spec, repo)
      assert slow.status == :timeout
      assert never.status == :skipped
      assert never.output =~ "budget"
      refute File.exists?(marker)
    end

    test "a failure outranks a later timeout in the overall result", %{repo: repo} do
      spec =
        spec([step("bad", "exit 3"), step("slow", "sleep 5", %{"timeout_s" => 1})])

      assert %{result: {:failed, 3, _}} = PrepushCheck.run_steps(spec, repo)
    end

    test "{elixir_files} and {test_files} expand to the touched files of the branch", %{
      repo: repo,
      tmp_dir: dir
    } do
      commit_change(repo, "lib/a.ex")
      out = Path.join(dir, "out.txt")

      spec =
        spec([
          step("lint", "echo {elixir_files} > #{out}.lint", %{"scope" => "touched"}),
          step("tests", "echo {test_files} > #{out}.tests", %{"scope" => "touched"})
        ])

      assert %{result: :ok} = PrepushCheck.run_steps(spec, repo, target: "main")
      assert File.read!(out <> ".lint") == "lib/a.ex\n"
      assert File.read!(out <> ".tests") == "test/a_test.exs\n"
    end

    test "a touched step with nothing to run is skipped", %{repo: repo, tmp_dir: dir} do
      commit_change(repo, "README.md")
      marker = Path.join(dir, "ran")

      spec =
        spec([step("lint", "touch #{marker} {elixir_files}", %{"scope" => "touched"})])

      assert %{result: :ok, steps: [%{status: :skipped}]} =
               PrepushCheck.run_steps(spec, repo, target: "main")

      refute File.exists?(marker)
    end

    test "when the diff base is unknown a touched step runs unscoped", %{repo: repo, tmp_dir: dir} do
      out = Path.join(dir, "unscoped")
      spec = spec([step("lint", "echo [{elixir_files}] > #{out}", %{"scope" => "touched"})])

      assert %{result: :ok, steps: [%{status: :passed}]} =
               PrepushCheck.run_steps(spec, repo, target: "no-such-ref")

      assert File.read!(out) == "[]\n"
    end

    test "the :exec hook runs the steps instead of the host (the sandbox path)", %{repo: repo} do
      test_pid = self()

      exec = fn command, timeout_s ->
        send(test_pid, {:exec, command, timeout_s})
        {"from the container", 1}
      end

      spec = spec([step("in-box", "mix format --check-formatted", %{"timeout_s" => 42})])

      assert %{result: {:failed, 1, "from the container"}} =
               PrepushCheck.run_steps(spec, repo, exec: exec)

      assert_received {:exec, "mix format --check-formatted", 42}
    end

    test "an :exec hook error is an infra error and fails open", %{repo: repo} do
      exec = fn _command, _timeout_s -> {:error, :podman_gone} end
      spec = spec([step("in-box", "true")])

      assert %{result: {:error, _}, steps: [%{status: :error}]} =
               PrepushCheck.run_steps(spec, repo, exec: exec)
    end

    test "a spec without steps (the legacy shape) still runs its command", %{repo: repo} do
      legacy = %{command: "echo legacy; exit 4", timeout_seconds: 30, on_timeout: :proceed}
      assert %{result: {:failed, 4, out}} = PrepushCheck.run_steps(legacy, repo)
      assert out =~ "legacy"
    end
  end
end
