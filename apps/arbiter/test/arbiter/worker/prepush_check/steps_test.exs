defmodule Arbiter.Worker.PrepushCheck.StepsTest do
  @moduledoc """
  bd-8wdrql: the multi-step recipe (`worker.repos.<repo>.pre_push_checks`) —
  resolution, the total time budget, touched-file scoping, and the per-step
  results `run_steps/3` returns for the run's step rows.
  """

  # async: false: it points the global :worker_tmp_root at a per-test dir, which races
  # with the same dance in PrepushCheckTest if both run concurrently.
  use ExUnit.Case, async: false

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

    test "a missing-deps failure is infra: the step is skipped, never a code failure", %{
      repo: repo
    } do
      script =
        "echo 'Unchecked dependencies for environment test:' 1>&2; " <>
          "echo '* ash (Hex package)' 1>&2; " <>
          "echo '  the dependency is not available, run \"mix deps.get\"' 1>&2; exit 1"

      spec = spec([step("compile", script), step("fmt", "true")])

      assert %{result: {:error, {:infra, "compile", _}}, steps: [compile, fmt]} =
               PrepushCheck.run_steps(spec, repo)

      assert compile.status == :skipped
      assert compile.reason == :infra
      assert compile.exit_status == nil
      assert compile.output =~ "skipped: infra"
      assert compile.output =~ "the dependency is not available"
      assert fmt.status == :passed
    end

    test "other infra signatures: unknown import_deps dep, missing tool, container errors",
         %{repo: repo} do
      for output <- [
            "** (Mix) Unknown dependency :ash_phoenix given to :import_deps in the formatter configuration",
            "sh: 1: mix: not found",
            "Error: crun: executable file `mix` not found in $PATH: No such file or directory",
            "Error: creating container storage: the image is not known",
            "Cannot connect to Podman. Please verify your connection to the Linux system"
          ] do
        spec = spec([step("s", "printf '%s\\n' '#{output}'; exit 1")])

        assert %{result: {:error, {:infra, "s", _}}, steps: [%{status: :skipped, reason: :infra}]} =
                 PrepushCheck.run_steps(spec, repo),
               "expected infra for: #{output}"
      end
    end

    test "a real failure that merely mentions a path is still a code failure", %{repo: repo} do
      spec = spec([step("fmt", "echo 'lib/a.ex is not formatted'; exit 1")])

      assert %{result: {:failed, 1, _}, steps: [%{status: :failed}]} =
               PrepushCheck.run_steps(spec, repo)
    end

    test "an infra step does not hide a real failure in another step", %{repo: repo} do
      spec =
        spec([
          step("deps", "echo 'run mix deps.get' 1>&2; exit 1"),
          step("credo", "echo real-red; exit 2")
        ])

      assert %{result: {:failed, 2, "real-red"}} = PrepushCheck.run_steps(spec, repo)
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

    # bd-9xcogk: what every step printed on bd-5w9hgm / bd-325sps once the run's
    # egress proxy was gone and `lazy_html` (a test-only NIF dep) was not compiled.
    @lazy_html_failure """
    Using HTTP_PROXY: http://127.0.0.1:3128
    Error happened while installing lazy_html from precompiled binary: cannot download: :enoent
    fatal: unable to access 'https://github.com/lexbor/lexbor.git/': Failed to connect to 127.0.0.1 port 3128
    ** (Mix) Could not compile with "make" (exit status: 2).
    """

    test "a dependency that cannot be built or fetched offline is infra, not a code failure",
         %{repo: repo} do
      exec = fn _command, _timeout_s -> {@lazy_html_failure, 1} end
      spec = spec([step("compile", "true")])

      assert %{result: {:error, {:infra, "compile", label}}, steps: [compile]} =
               PrepushCheck.run_steps(spec, repo, exec: exec)

      assert label =~ "fetch or build a dependency"
      assert compile.status == :skipped and compile.reason == :infra
      assert compile.output =~ "skipped: infra"
    end

    test "each piece of that failure is infra on its own", %{repo: repo} do
      for output <- [
            "Error happened while installing lazy_html from precompiled binary: cannot download",
            "** (Mix) Command \"git --git-dir=.git fetch\" failed\nfatal: unable to access 'https://github.com/x/y.git/': Failed to connect to 127.0.0.1 port 3128",
            "** (Mix) Could not compile with \"make\" (exit status: 2).",
            "** (Mix) Could not resolve host: repo.hex.pm",
            "Failed to fetch record for 'hexpm/ash' from registry (using cache): :econnrefused"
          ] do
        spec = spec([step("compile", "true")])

        assert %{result: {:error, {:infra, "compile", _}}} =
                 PrepushCheck.run_steps(spec, repo, exec: fn _, _ -> {output, 1} end),
               "not infra: #{output}"
      end
    end

    # bd-4uom27: what every step printed on a node run (bd-7yj8qv) whose seed lacked
    # `mdex_native`, a `rustler_precompiled` NIF: a different library and a different
    # message from the `elixir_make` one above.
    @mdex_native_failure """
    ==> mdex_native
    Compiling 1 file (.ex)
    ** (RuntimeError) Error while downloading precompiled NIF: couldn't fetch NIF from https://github.com/leandrocp/mdex_native/releases/download/v0.2.8/libmdex_native_nif-v0.2.8-nif-2.16-x86_64-unknown-linux-gnu.so.tar.gz: {:failed_connect, [{:to_address, {~c"github.com", 443}}, {:inet, [:inet], :nxdomain}]}

        (rustler_precompiled 0.9.0) lib/rustler_precompiled.ex:773: RustlerPrecompiled.download_or_reuse_nif_file/3
    could not compile dependency :mdex_native, "mix compile" failed. Errors may have been logged above.
    """

    test "a precompiled NIF that cannot be downloaded is infra, not a code failure",
         %{repo: repo} do
      spec = spec([step("compile", "true")])

      assert %{result: {:error, {:infra, "compile", label}}, steps: [compile]} =
               PrepushCheck.run_steps(spec, repo, exec: fn _, _ -> {@mdex_native_failure, 1} end)

      assert label =~ "fetch or build a dependency"
      assert compile.status == :skipped and compile.reason == :infra
    end

    test "a dependency that fails to compile for any reason is infra, whatever it says",
         %{repo: repo} do
      spec = spec([step("compile", "true")])

      for output <- [
            "** (RuntimeError) Error while downloading precompiled NIF: couldn't fetch NIF",
            "== Compilation error in file lib/foo.ex ==\n** (CompileError) lib/foo.ex:1: boom\ncould not compile dependency :jason, \"mix compile\" failed. Errors may have been logged above.",
            "could not compile dependency :some_nif, \"mix compile\" failed. Unable to find the NIF"
          ] do
        assert %{result: {:error, {:infra, "compile", _}}} =
                 PrepushCheck.run_steps(spec, repo, exec: fn _, _ -> {output, 1} end),
               "not infra: #{output}"
      end
    end

    test "once a step could not download a NIF, the rest are skipped unrun", %{repo: repo} do
      test_pid = self()

      exec = fn command, _timeout_s ->
        send(test_pid, {:ran, command})
        {@mdex_native_failure, 1}
      end

      spec = spec([step("format", "one"), step("compile", "two"), step("credo", "three")])

      assert %{result: {:error, {:infra, "format", _}}, steps: steps} =
               PrepushCheck.run_steps(spec, repo, exec: exec)

      assert_received {:ran, "one"}
      refute_received {:ran, "two"}
      refute_received {:ran, "three"}
      assert Enum.all?(steps, &(&1.status == :skipped and &1.reason == :infra))
    end

    test "a failure in the project's own umbrella app is a code failure, not a dependency one",
         %{repo: repo} do
      File.mkdir_p!(Path.join(repo, "apps/my_app"))
      spec = spec([step("compile", "true")])

      out =
        "== Compilation error in file lib/my_app/a.ex ==\n** (CompileError) lib/my_app/a.ex:3: undefined function nope/0\ncould not compile dependency :my_app, \"mix compile\" failed. Errors may have been logged above."

      assert %{result: {:failed, 1, _}} =
               PrepushCheck.run_steps(spec, repo, exec: fn _, _ -> {out, 1} end)
    end

    test "a bare network error with no Mix dependency context is a code failure", %{repo: repo} do
      spec = spec([step("tests", "true")])

      out =
        "fatal: unable to access 'https://github.com/x/y.git/': Failed to connect to 127.0.0.1 port 3128"

      assert %{result: {:failed, 1, ^out}} =
               PrepushCheck.run_steps(spec, repo, exec: fn _, _ -> {out, 1} end)
    end

    test "a real compile error that merely mentions make is still a code failure", %{repo: repo} do
      spec = spec([step("compile", "true")])
      out = "** (CompileError) lib/a.ex:3: undefined function make_thing/0"

      assert %{result: {:failed, 1, ^out}} =
               PrepushCheck.run_steps(spec, repo, exec: fn _, _ -> {out, 1} end)
    end

    test "once a step finds the deps unusable offline, the rest are skipped unrun", %{repo: repo} do
      test_pid = self()

      exec = fn command, _timeout_s ->
        send(test_pid, {:ran, command})
        {@lazy_html_failure, 1}
      end

      spec = spec([step("compile", "one"), step("credo", "two"), step("tests", "three")])

      assert %{result: {:error, {:infra, "compile", _}}, steps: [first, second, third]} =
               PrepushCheck.run_steps(spec, repo, exec: exec)

      assert_received {:ran, "one"}
      refute_received {:ran, "two"}
      refute_received {:ran, "three"}

      for step <- [first, second, third] do
        assert step.status == :skipped and step.reason == :infra
      end
    end

    test "bare git/curl network errors are infra only beside Mix's own dependency report",
         %{repo: repo} do
      spec = spec([step("compile", "true")])

      infra = [
        "==> lazy_html\nfatal: unable to access 'https://github.com/x.git/': Failed to connect to 127.0.0.1 port 3128\n** (Mix) Could not fetch",
        "** (Mix) Failed to fetch record for 'hexpm/ash' from registry\ncurl: Could not resolve host: repo.hex.pm"
      ]

      for output <- infra do
        assert %{result: {:error, {:infra, "compile", _}}} =
                 PrepushCheck.run_steps(spec, repo, exec: fn _, _ -> {output, 1} end),
               "should be infra: #{output}"
      end

      code = [
        # a test that shells out to git and prints its captured stderr
        "  1) test pushes (GitTest)\n     fatal: unable to access 'https://example.test/r.git/': Failed to connect to localhost port 9 after 0 ms\n\n1 test, 1 failure",
        # the same stderr with a Mix banner earlier in the run, and a failure summary
        "** (Mix) something\nfatal: unable to access 'https://x/': Could not resolve host: x\n12 tests, 2 failures",
        # no Mix context at all
        "fatal: unable to access 'https://example.test/r.git/': Failed to connect to localhost port 9"
      ]

      for output <- code do
        assert %{result: {:failed, 1, _}} =
                 PrepushCheck.run_steps(spec, repo, exec: fn _, _ -> {output, 1} end),
               "should be a code failure: #{output}"
      end
    end

    # bd-9xcogk: a worktree seeded from a compiled checkout reaches its NIF through
    # `_build/<env>/lib/lazy_html/priv`, an absolute link into that checkout. Once the
    # checkout (or the seed's scratch dir) is gone the gate's steps used to find no
    # `lazy_html` and try to fetch it. Every step runs, with the NIF there, no proxy.
    test "a freshly seeded worktree runs every step with the compiled NIF in place",
         %{repo: repo, tmp_dir: dir} do
      source = Path.join(dir, "source")
      File.mkdir_p!(Path.join(source, "deps/lazy_html/priv"))
      File.write!(Path.join(source, "deps/lazy_html/priv/lazy_html.so"), "nif\n")
      lib = Path.join(source, "_build/test/lib/lazy_html")
      File.mkdir_p!(Path.join(lib, "ebin"))
      File.ln_s!(Path.join(source, "deps/lazy_html/priv"), Path.join(lib, "priv"))

      assert :ok = Arbiter.Worker.Worktree.seed_compiled_deps(source, repo)
      File.rm_rf!(source)

      test_pid = self()
      nif = Path.join(repo, "_build/test/lib/lazy_html/priv/lazy_html.so")

      exec = fn command, _timeout_s ->
        send(test_pid, {:ran, command, File.exists?(nif)})
        {"", 0}
      end

      spec = spec([step("compile", "one"), step("credo", "two"), step("tests", "three")])

      assert %{result: :ok, steps: steps} = PrepushCheck.run_steps(spec, repo, exec: exec)
      assert Enum.all?(steps, &(&1.status == :passed))

      for command <- ~w(one two three) do
        assert_received {:ran, ^command, true}
      end
    end

    test "the gate repairs a worktree seeded before the fix (dangling priv link) before step one",
         %{repo: repo, tmp_dir: dir} do
      File.mkdir_p!(Path.join(repo, "deps/lazy_html/priv"))
      File.write!(Path.join(repo, "deps/lazy_html/priv/lazy_html.so"), "nif\n")
      lib = Path.join(repo, "_build/test/lib/lazy_html")
      File.mkdir_p!(lib)
      File.ln_s!(Path.join(dir, "gone/deps/lazy_html/priv"), Path.join(lib, "priv"))

      test_pid = self()
      nif = Path.join(lib, "priv/lazy_html.so")

      exec = fn command, _timeout_s ->
        send(test_pid, {:ran, command, File.exists?(nif)})
        {"", 0}
      end

      assert %{result: :ok} =
               PrepushCheck.run_steps(spec([step("tests", "one")]), repo, exec: exec)

      assert_received {:ran, "one", true}
    end

    test "a loopback egress proxy inherited from the server is not passed to host steps",
         %{repo: repo} do
      for name <- ~w(HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy) do
        System.put_env(name, "http://127.0.0.1:3128")
        on_exit(fn -> System.delete_env(name) end)
      end

      spec = spec([step("env", "echo \"proxy=[$HTTP_PROXY$https_proxy$ALL_PROXY]\"; exit 1")])
      assert %{result: {:failed, 1, out}} = PrepushCheck.run_steps(spec, repo)
      assert out =~ "proxy=[]"
    end

    test "a real (non-loopback) proxy the operator configured is kept", %{repo: repo} do
      System.put_env("HTTPS_PROXY", "http://proxy.corp.example:8080")
      on_exit(fn -> System.delete_env("HTTPS_PROXY") end)

      spec = spec([step("env", "echo \"proxy=$HTTPS_PROXY\"; exit 1")])
      assert %{result: {:failed, 1, out}} = PrepushCheck.run_steps(spec, repo)
      assert out =~ "proxy=http://proxy.corp.example:8080"
    end

    test "a spec without steps (the legacy shape) still runs its command", %{repo: repo} do
      legacy = %{command: "echo legacy; exit 4", timeout_seconds: 30, on_timeout: :proceed}
      assert %{result: {:failed, 4, out}} = PrepushCheck.run_steps(legacy, repo)
      assert out =~ "legacy"
    end
  end
end
