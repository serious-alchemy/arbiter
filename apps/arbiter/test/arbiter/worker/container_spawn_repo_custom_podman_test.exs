defmodule Arbiter.Worker.ContainerSpawnRepoCustomPodmanTest do
  @moduledoc """
  bd-83gbsh (#1040): a claude and a codex spawn from a REPO-CUSTOM image (a repo's
  own `.arbiter/Containerfile` with no `USER`, like vstim's), through the real
  `ContainerSpawn.prepare/1` + `wrap_port/1`, against a real rootless podman.

  The v0.2.84 failure was the agent running as uid 0 (the image ended on
  `USER root`, which overrides `--userns=keep-id`), so codex got "config.toml:
  Permission denied" and claude "EACCES mkdir …/claude-0". The CLIs here are
  stand-ins from `CliSetFixture` (small shell scripts mounted where the SI1 CLI
  set mounts the real ones); each does the first things the real CLI does at
  start-up: report its uid, read its config, create its scratch/config dirs. So
  this proves the spawn's identity and file access, not the real binaries' own
  start-up (run `codex --version` / `claude --version` in a real spawn for that).

  Opt-in, because it builds an image and starts containers:

      cd apps/arbiter && mix test --include podman \\
        test/arbiter/worker/container_spawn_repo_custom_podman_test.exs

  It removes the images it built by exact tag (never a pattern).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Test.GitFixture
  alias Arbiter.Test.StubMcpServer
  alias Arbiter.Worker.CliSetFixture
  alias Arbiter.Worker.ContainerSpawn
  alias Arbiter.Worker.Egress.JailRun
  alias Arbiter.Worker.Image
  alias Arbiter.Worker.Image.Builder
  alias Arbiter.Worker.PrivateClone
  alias Arbiter.Worker.RunTmp

  @moduletag :podman
  @moduletag timeout: 900_000

  # What codex does first: load $CODEX_HOME/config.toml, then a scratch file in $TMPDIR.
  @codex_stand_in """
  #!/bin/sh
  : "${TMPDIR:?TMPDIR is not set in the container}"
  echo "codex uid=$(id -u)"
  cat "$CODEX_HOME/config.toml" > /dev/null || { echo "codex: config.toml unreadable"; exit 13; }
  : > "$TMPDIR/codex-probe" || { echo "codex: TMPDIR unwritable"; exit 14; }
  echo codex-started
  """

  # What claude does first: its per-uid scratch dir under $TMPDIR, then its config dir.
  @claude_stand_in """
  #!/bin/sh
  : "${TMPDIR:?TMPDIR is not set in the container}"
  echo "claude uid=$(id -u)"
  mkdir "$TMPDIR/claude-$(id -u)" || { echo "claude: mkdir EACCES"; exit 13; }
  : > "$CLAUDE_CONFIG_DIR/claude-probe" || { echo "claude: config dir unwritable"; exit 14; }
  echo claude-started
  """

  defp git!(dir, args) do
    {out, 0} =
      System.cmd(
        "git",
        ["-C", dir, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"] ++
          args,
        stderr_to_stdout: true
      )

    out
  end

  setup do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    dir = Path.join(System.tmp_dir!(), "spawn-custom-podman-#{suffix}")
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, ".arbiter"))
    on_exit(fn -> File.rm_rf!(dir) end)

    git!(repo, ["init", "-q", "-b", "main"])

    # No USER of its own, like vstim's: it inherits the base's identity.
    File.write!(
      Path.join(repo, ".arbiter/Containerfile"),
      "FROM ${ARBITER_BASE}\nRUN echo repo-custom-#{suffix} > /marker\n"
    )

    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "init"])

    builder = start_supervised!({Builder, name: nil})

    opts = [
      root: Path.join(dir, "state"),
      scratch: Path.join(dir, "scratch"),
      server: builder,
      repo_name: suffix
    ]

    {:ok, plan} = Image.plan(repo, "main", opts)

    on_exit(fn ->
      for tag <- [plan.tag, plan.base.tag], do: System.cmd("podman", ["rmi", tag])
    end)

    assert {:ok, %{tag: tag}} = Image.ensure(repo, "main", opts)

    ctx = GitFixture.forge_and_checkout(%{"README.md" => "readme\n"})
    {:ok, clone} = PrivateClone.create(ctx.checkout, "feature/bd-83gbsh", "main")
    {:ok, mcp} = StubMcpServer.start(self())
    on_exit(fn -> StubMcpServer.stop(mcp) end)

    prior = Application.get_env(:arbiter, Arbiter.MCP)
    url = "http://127.0.0.1:#{mcp.port}/mcp"

    Application.put_env(
      :arbiter,
      Arbiter.MCP,
      Keyword.merge(prior || [], url: url, inject_config: true)
    )

    on_exit(fn ->
      if prior,
        do: Application.put_env(:arbiter, Arbiter.MCP, prior),
        else: Application.delete_env(:arbiter, Arbiter.MCP)
    end)

    for {key, value} <- [
          worker_container_available: true,
          worker_container_network_available: true
        ] do
      previous = Application.get_env(:arbiter, key)
      Application.put_env(:arbiter, key, value)

      on_exit(fn ->
        if previous == nil,
          do: Application.delete_env(:arbiter, key),
          else: Application.put_env(:arbiter, key, previous)
      end)
    end

    cli_opts =
      CliSetFixture.put(Path.join(dir, "cli"),
        content: %{"codex" => @codex_stand_in, "claude" => @claude_stand_in}
      )

    {:ok, tag: tag, clone: clone, mcp_url: url, cli_opts: cli_opts, run_root: ctx.root}
  end

  defp policy do
    SecurityPolicy.merge(SecurityPolicy.base(), %{"sandbox" => %{"backend" => "podman"}})
  end

  defp spawn_and_run(ctx, provider) do
    tmp_dir = Path.join(ctx.run_root, "run-tmp-#{provider}")
    File.mkdir_p!(tmp_dir)
    source_home = Path.join(ctx.run_root, "codex-source")
    File.mkdir_p!(source_home)

    {:ok, request} =
      ContainerSpawn.prepare(
        [
          provider: provider,
          policy: policy(),
          worktree_path: ctx.clone,
          owner: self(),
          task_id: "bd-83gbsh",
          arb_token: "arb-token",
          tmp_dir: tmp_dir,
          codex_source_home: source_home,
          image: ctx.tag,
          deps_cache: false,
          services: [],
          egress: fn opts -> JailRun.start([arbiter_url: ctx.mcp_url] ++ opts) end
        ] ++ ctx.cli_opts
      )

    on_exit(fn -> ContainerSpawn.teardown(%{sandbox: request}) end)

    port_args = %{
      exec: "/bin/sh",
      argv: ["sh", "-c", provider],
      cd: ctx.clone,
      # Dispatch's env carries the run's TMPDIR/TMP/TEMP (`RunTmp.env_pairs/1`);
      # `apply_env/2` repoints them for a codex container. An empty env would leave
      # TMPDIR unset in the container and the stand-ins would write to `/`.
      env: ContainerSpawn.apply_env(RunTmp.env_pairs(tmp_dir), request),
      sandbox: request
    }

    {:ok, wrapped} = ContainerSpawn.wrap_port(port_args)
    [_ | args] = wrapped.argv
    {out, status} = System.cmd(wrapped.exec, args, env: wrapped.env, stderr_to_stdout: true)
    {request, out, status}
  end

  for provider <- ["claude", "codex"] do
    test "#{provider} from a repo-custom image starts as the host uid, with no Permission denied",
         ctx do
      {host_uid, 0} = System.cmd("id", ["-u"])
      host_uid = String.trim(host_uid)

      {_request, out, status} = spawn_and_run(ctx, unquote(provider))

      assert status == 0, out
      refute out =~ "Read-only file system"
      refute out =~ "Permission denied"
      refute out =~ "EACCES"
      assert out =~ "#{unquote(provider)} uid=#{host_uid}"
      refute out =~ "#{unquote(provider)} uid=0\n"
      assert out =~ "#{unquote(provider)}-started"
    end
  end
end
