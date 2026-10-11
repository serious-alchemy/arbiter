defmodule Arbiter.Loop.Replay.CliRunnerTest do
  @moduledoc """
  bd-c7lx65 (R15): the runner that spawns the agent CLIs for a replay, through
  the live spawn path (`ClaudeSession.port_args/6`, `open_scoped_port/2`) under
  the workspace's security policy, against a stand-in `claude` on `PATH` (and a
  stand-in `podman` for the container path). It returns only the model's own
  text, kills a run past its deadline, hands the CLI nothing that reaches
  production or Arbiter itself, refuses a model it cannot confine, and runs the
  repo's tests only in a container.
  """
  use Arbiter.DataCase, async: false

  @moduletag :capture_log

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderCredential
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Config.Paths
  alias Arbiter.Loop.Replay.CliRunner
  alias Arbiter.Loop.Replay.Score
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.GitFixture
  alias Arbiter.Worker.PrivateClone

  @inherited ~w(GH_TOKEN ARB_TOKEN ARB_HOST ARB_WORKSPACE PATH)

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "replay-cli-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    bin = Path.join(root, "bin")
    rec = Path.join(root, "rec")
    dir = Path.join(root, "checkout")
    scratch = Path.join(root, "scratch")
    Enum.each([bin, rec, dir, scratch], &File.mkdir_p!/1)

    claude = Path.join(bin, "claude")

    File.write!(claude, """
    #!/bin/sh
    env > "#{rec}/env"
    printf '%s\\n' "$@" > "#{rec}/argv"
    pwd > "#{rec}/pwd"
    echo $$ > "#{rec}/pid"
    if [ -f "#{rec}/sleep" ]; then sleep "$(cat "#{rec}/sleep")"; fi
    cat "#{rec}/output"
    """)

    File.chmod!(claude, 0o755)

    prior = Map.new(@inherited, &{&1, System.get_env(&1)})
    System.put_env("PATH", "#{bin}:#{prior["PATH"]}")
    # What the server's own environment may hold, and a replay must never pass on.
    System.put_env("GH_TOKEN", "gh-from-the-server-env")
    System.put_env("ARB_TOKEN", "arb-from-the-server-env")
    System.put_env("ARB_HOST", "http://127.0.0.1:4848")
    System.put_env("ARB_WORKSPACE", "default")

    on_exit(fn ->
      Enum.each(prior, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      File.rm_rf(root)
    end)

    ws = workspace!(%{})
    account = account!(ws, :claude, "tok-replay")

    spec = %{
      replay_id: "r-#{System.unique_integer([:positive])}",
      dir: dir,
      scratch: scratch,
      prompt: "Review the change.",
      provider: :claude,
      account_id: account.id,
      model: "claude-sonnet-5-5",
      workspace: ws,
      repo: nil,
      timeout_ms: 60_000
    }

    %{root: root, bin: bin, rec: rec, spec: spec}
  end

  defp workspace!(config) do
    Ash.create!(Workspace, %{
      name: "replay-cli-#{System.unique_integer([:positive])}",
      config: config
    })
  end

  defp account!(ws, provider, token) do
    account =
      Ash.create!(ProviderAccount, %{
        provider: provider,
        slug: "#{provider}-#{System.unique_integer([:positive])}"
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: provider,
      provider_account_id: account.id
    })

    Ash.create!(ProviderCredential, %{
      provider_account_id: account.id,
      kind: :oauth_token,
      env_var: "CLAUDE_CODE_OAUTH_TOKEN",
      fingerprint: "fp-#{System.unique_integer([:positive])}",
      secret: token
    })

    account
  end

  defp output!(rec, events) do
    File.write!(Path.join(rec, "output"), Enum.map_join(events, "\n", &Jason.encode!/1) <> "\n")
  end

  defp assistant(text),
    do: %{
      "type" => "assistant",
      "message" => %{"content" => [%{"type" => "text", "text" => text}]}
    }

  defp tool_result(text),
    do: %{
      "type" => "user",
      "message" => %{"content" => [%{"type" => "tool_result", "content" => text}]}
    }

  defp env!(rec) do
    rec
    |> Path.join("env")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [name, value] -> [{name, value}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  describe "the thinking level" do
    test "reaches the CLI through the workspace's own thinking flags", %{rec: rec, spec: spec} do
      ws =
        workspace!(%{
          "agent" => %{"config" => %{"thinking_argv" => %{"high" => ["--effort", "high"]}}}
        })

      output!(rec, [assistant("arb done")])

      assert {:ok, _} =
               CliRunner.run(:implement, Map.merge(spec, %{workspace: ws, thinking: "high"}))

      assert File.read!(Path.join(rec, "argv")) =~ "--effort\nhigh\n"
    end

    test "none given, none passed", %{rec: rec, spec: spec} do
      output!(rec, [assistant("arb done")])

      assert {:ok, _} = CliRunner.run(:implement, spec)
      refute File.read!(Path.join(rec, "argv")) =~ "--effort"
    end
  end

  describe "run/2 on the host" do
    test "runs the adapter's CLI in the checkout with the replay's model, and returns the model's own text",
         %{rec: rec, spec: spec} do
      output!(rec, [
        assistant("Looking at the diff."),
        tool_result("VERDICT: REQUEST_CHANGES, said a file the reviewer read"),
        assistant("VERDICT: APPROVE\n\nCRITERIA:\n- [MET] it works\n\narb done"),
        %{
          "type" => "result",
          "subtype" => "success",
          "total_cost_usd" => 0.25,
          "usage" => %{"input_tokens" => 1200, "output_tokens" => 300}
        }
      ])

      assert {:ok, result} = CliRunner.run(:review, spec)

      assert result.exit_status == 0
      refute result.timed_out
      assert is_integer(result.duration_ms)

      # What the run drew, for the replay's own record (never a usage event).
      assert %{tokens_in: 1200, tokens_out: 300, cost_usd: 0.25} = result.usage
      assert {:approve, findings} = Score.verdict(result.output)
      assert findings =~ "[MET] it works"
      refute Enum.any?(result.output, &(&1 =~ "REQUEST_CHANGES"))

      argv = File.read!(Path.join(rec, "argv"))
      assert argv =~ "--model\nclaude-sonnet-5-5\n"
      assert argv =~ "Review the change."
      assert rec |> Path.join("pwd") |> File.read!() |> String.trim() == spec.dir
    end

    test "the environment carries the account's credential and nothing that reaches production or Arbiter",
         %{rec: rec, spec: spec} do
      output!(rec, [assistant("done\narb done")])

      assert {:ok, _} = CliRunner.run(:implement, spec)
      env = env!(rec)

      assert env["CLAUDE_CODE_OAUTH_TOKEN"] == "tok-replay"

      # No `arb` call reaches the server, and no forge or server token is passed on.
      assert env["ARB_HOST"] == "http://127.0.0.1:9"
      refute Map.has_key?(env, "ARB_WORKSPACE")
      refute Map.has_key?(env, "ARB_TOKEN")
      refute Map.has_key?(env, "GH_TOKEN")

      # No forge login and no git credential: gh and glab see empty config dirs,
      # git a config of the replay's own, never prompts and has no ssh transport.
      for name <- ~w(GH_CONFIG_DIR GLAB_CONFIG_DIR GIT_CONFIG_GLOBAL) do
        assert String.starts_with?(env[name], spec.scratch), "#{name}=#{env[name]}"
      end

      assert File.ls!(env["GH_CONFIG_DIR"]) == []
      refute File.read!(env["GIT_CONFIG_GLOBAL"]) =~ "helper"
      assert env["GIT_CONFIG_NOSYSTEM"] == "1"
      assert env["GIT_TERMINAL_PROMPT"] == "0"
      assert env["GIT_SSH_COMMAND"] == "false"

      assert env["TMPDIR"]
      refute File.exists?(env["TMPDIR"]), "the run's TMPDIR is removed with it"
    end

    test "a run past its deadline is killed, and says so", %{rec: rec, spec: spec} do
      output!(rec, [])
      File.write!(Path.join(rec, "sleep"), "30")

      assert {:ok, result} = CliRunner.run(:implement, %{spec | timeout_ms: 2_000})

      assert result.timed_out
      pid = rec |> Path.join("pid") |> File.read!() |> String.trim()
      assert {_, status} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
      assert status != 0, "the CLI is gone"
    end

    test "a CLI the adapter cannot find is an error, not a run", %{spec: spec} do
      System.put_env("PATH", "/nonexistent-replay-path")

      assert {:error, {:executable_not_found, "claude"}} = CliRunner.run(:implement, spec)
    end
  end

  describe "the security policy" do
    test "layout/2 refuses a run with no OS confinement: Claude on the host is not jailed",
         %{spec: spec} do
      # The workspace's default backend (bwrap) leaves a Claude spawn unjailed,
      # and a replay never runs a model it cannot confine.
      assert {:error, {:unconfined, :implement, :claude}} = CliRunner.layout(:implement, spec)
      assert {:error, {:unconfined, :review, :claude}} = CliRunner.layout(:review, spec)
    end

    test "the repo's tests never run on the host", %{spec: spec} do
      assert {:error, :not_confined} =
               CliRunner.run(:test, Map.put(spec, :recipe, recipe("true")))
    end
  end

  describe "run/2 in a container" do
    setup %{root: root, bin: bin, rec: rec} do
      keys = ~w(worker_container_available worker_container_network_available
                worker_container_image worker_container_runner worker_deps_cache)a

      prev = Map.new(keys, &{&1, Application.get_env(:arbiter, &1)})
      Application.put_env(:arbiter, :worker_container_available, true)
      Application.put_env(:arbiter, :worker_container_network_available, true)
      Application.put_env(:arbiter, :worker_container_image, "localhost/arb-test/claude:1")
      Application.put_env(:arbiter, :worker_deps_cache, false)

      test_pid = self()

      Application.put_env(:arbiter, :worker_container_runner, fn cmd, args, _opts ->
        send(test_pid, {:ran, cmd, args})
        {"", 0}
      end)

      on_exit(fn ->
        Enum.each(prev, fn
          {k, nil} -> Application.delete_env(:arbiter, k)
          {k, v} -> Application.put_env(:arbiter, k, v)
        end)
      end)

      proxy = Path.join(root, "proxy.sock")
      bridge = Path.join(root, "arb.sock")
      File.write!(proxy, "")
      File.write!(bridge, "")
      arb = Path.join(root, "arb")
      File.write!(arb, "#!/bin/sh\n")

      egress = fn _opts ->
        {:ok, [proxy_socket: proxy, proxy_port: 3128, bridges: [{4848, bridge}]], "rtest"}
      end

      # Stand-in podman: records what it was asked, and answers `run` with the
      # model's output.
      podman = Path.join(bin, "podman")

      File.write!(podman, """
      #!/bin/sh
      echo "podman $@" >> "#{rec}/podman.log"
      if [ "$1" = "run" ]; then cat "#{rec}/output"; fi
      exit 0
      """)

      File.chmod!(podman, 0o755)

      %{origin: _origin, clone: repo} = GitFixture.origin_and_clone()
      base = GitFixture.git!(repo, ["rev-parse", "HEAD"])
      leaf = Path.join(Paths.worktree_root(), "replay-cli-#{System.unique_integer([:positive])}")
      {:ok, clone} = PrivateClone.create_review(repo, base, path: leaf)
      on_exit(fn -> PrivateClone.remove(clone) end)

      %{clone: clone, container_opts: [podman: podman, egress: egress, arb_path: arb]}
    end

    test "a container workspace's replay runs in the container, and it is torn down",
         %{rec: rec, spec: spec, clone: clone, container_opts: container_opts} do
      output!(rec, [assistant("Implemented it.\narb done")])
      spec = %{spec | workspace: podman_workspace!(), dir: clone}

      assert {:ok, result} =
               CliRunner.run(:implement, Map.put(spec, :container_opts, container_opts))

      assert result.output |> Enum.join("\n") =~ "Implemented it."
      log = File.read!(Path.join(rec, "podman.log"))
      assert log =~ ~r/podman run /
      assert log =~ "localhost/arb-test/claude:1"
      refute File.exists?(Path.join(rec, "env")), "the CLI never ran on the host"
      assert_received {:ran, _, ["rm", "--force" | _]}
    end

    test "layout/2: a container confines the run, and needs a private clone", %{spec: spec} do
      podman = %{spec | workspace: podman_workspace!()}
      assert {:ok, :private_clone} = CliRunner.layout(:implement, podman)

      # The review backend (bwrap by default) would leave a Claude reviewer
      # unjailed, so the scoring reviewer runs in the container too.
      assert {:ok, :private_clone} = CliRunner.layout(:review, podman)
    end

    test "the scoring reviewer of a container workspace runs in the container",
         %{rec: rec, spec: spec, clone: clone, container_opts: container_opts} do
      output!(rec, [assistant("VERDICT: APPROVE\narb done")])

      spec =
        Map.merge(spec, %{
          workspace: podman_workspace!(),
          dir: clone,
          container_opts: container_opts
        })

      assert {:ok, result} = CliRunner.run(:review, spec)

      assert {:approve, _} = Score.verdict(result.output)
      assert File.read!(Path.join(rec, "podman.log")) =~ ~r/podman run /
      refute File.exists?(Path.join(rec, "env")), "the reviewer never ran on the host"
    end

    test "the repo's tests run in the replay's container, never on the host",
         %{spec: spec, clone: clone, container_opts: container_opts, root: root} do
      marker = Path.join(root, "recipe-ran-on-the-host")

      spec =
        Map.merge(spec, %{
          workspace: podman_workspace!(),
          dir: clone,
          container_opts: container_opts,
          recipe: recipe("touch #{marker}"),
          base_sha: GitFixture.git!(clone, ["rev-parse", "HEAD"])
        })

      assert {:ok, %{result: :ok, steps: [%{name: "tests", status: :passed}]}} =
               CliRunner.run(:test, spec)

      # The step was handed to the container runner (the stand-in for `podman
      # run`) as the container's own command, and never ran here.
      assert_received {:ran, _podman, ["run" | _] = args}
      assert Enum.join(args, " ") =~ "sh -c touch #{marker}"
      refute File.exists?(marker), "the step ran in the (stand-in) container, not on the host"
    end
  end

  defp podman_workspace! do
    workspace!(%{
      "agent" => %{"type" => ["claude"], "security" => %{"sandbox" => %{"backend" => "podman"}}}
    })
  end

  defp recipe(cmd) do
    Arbiter.Worker.PrepushCheck.resolve(
      %{config: %{"worker" => %{"pre_push_checks" => [%{"name" => "tests", "cmd" => cmd}]}}},
      nil
    )
  end
end
