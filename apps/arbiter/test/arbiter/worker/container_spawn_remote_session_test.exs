defmodule Arbiter.Worker.ContainerSpawnRemoteSessionTest do
  @moduledoc """
  bd-4ic681: a session resume placed on a node (`claude --resume <sid>`) needs the
  prior session's JSONL in the run's config dir **on the node**, at the slug of the
  run's cwd (the primary's worktree path: path transparency). `remote_spec/3` seeds a
  **redacted** copy into the run's config dir on the primary, where the node's own
  transcript uploads land, and names it in the spec (`mounts.config_dir.session`:
  path, size, sha256) for the node to fetch; the bytes never ride the channel.
  """
  # async: false — swaps the :output_log_root application env.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.ClaudeSessionFile
  alias Arbiter.Worker.ContainerSpawn
  alias Arbiter.Workers.Run

  @sid "6f1e0c52-3c7a-4a55-9d0e-6b1c1f6a2b10"
  @workspace_secret "tok_SUPERSECRET_9d1"
  @oauth "sk-ant-oat01-OAUTHVALUE0123456789abcdefghij"
  @unregistered "ghp_UNREGISTEREDTOKEN0123456789abcdefgh"

  setup do
    base = Path.join(System.tmp_dir!(), "remote-session-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    put_app_env(:arbiter, :output_log_root, Path.join(base, "logs"))

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rs-#{System.unique_integer([:positive])}",
        worker_env: %{"API_TOKEN" => %{"value" => @workspace_secret, "secret" => true}}
      })

    {:ok, task} = Ash.create(Issue, %{title: "resumed on a node", workspace_id: ws.id})

    proxy = Path.join(base, "proxy.sock")
    File.write!(proxy, "")
    worktree = "/home/arb/worktrees/feature-1-#{task.id}"

    request = %{
      name: "arb-t-1",
      provider: "claude",
      image: %{tag: "localhost/x:1", plan: nil},
      worktree: worktree,
      home: Path.join(base, "run/home"),
      config_dir: Path.join(base, "run/claude-config"),
      config_files: %{},
      tmp_dir: Path.join(base, "run"),
      cli: [],
      prompt_paths: [],
      network: [proxy_socket: proxy, socat: "socat"],
      env: [],
      services: [],
      limits: %{},
      checkout: %{home: Path.join(base, "home"), branch: "arbiter/x", base: "main"},
      worktree_secrets: %{"ARBITER_MCP_TOKEN" => "scope-token-of-this-run"},
      task_id: task.id
    }

    %{base: base, task: task, request: request}
  end

  # The prior run's transcript, where the primary keeps it (its config dir, the node's
  # upload landed there), under the slug of that run's own cwd.
  defp prior_transcript!(%{base: base, task: task}, lines) do
    config = Path.join(base, "prior-config")
    path = Path.join([config, "projects", "-old-cwd", @sid <> ".jsonl"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(lines, "", &(Jason.encode!(&1) <> "\n")))

    {:ok, _} =
      Ash.create(Run, %{
        task_id: task.id,
        task_title: "t",
        repo: "r/r",
        state: :finished,
        outcome: :interrupted,
        started_at: DateTime.utc_now(),
        session_id: @sid,
        config_dir: config,
        provider: "claude"
      })

    path
  end

  defp resume_args(env \\ []),
    do: %{argv: ["claude", "--print", "--resume", @sid, "continue"], env: env}

  defp config_mount(spec), do: Enum.find(spec["mounts"], &(&1["kind"] == "config_dir"))

  test "a --resume argv seeds the session, redacted, at the slug of the run's cwd", ctx do
    prior_transcript!(ctx, [
      %{"type" => "user", "message" => "export API_TOKEN=#{@workspace_secret}"},
      %{"type" => "assistant", "message" => "the login is #{@oauth}"},
      %{"type" => "tool_result", "content" => "found #{@unregistered} in a log"},
      %{"type" => "assistant", "message" => "ok, carrying on"}
    ])

    env = [{"CLAUDE_CODE_OAUTH_TOKEN", @oauth}, {"TMPDIR", ctx.request.tmp_dir}]
    assert {:ok, spec} = ContainerSpawn.remote_spec(ctx.request, resume_args(env), "run-1")

    slug = ClaudeSessionFile.project_slug(ctx.request.worktree)
    rel = "projects/#{slug}/#{@sid}.jsonl"

    assert %{"path" => ^rel, "bytes" => bytes, "sha256" => sha} = config_mount(spec)["session"]

    seeded = File.read!(Path.join(ctx.request.config_dir, rel))
    assert byte_size(seeded) == bytes
    assert Base.encode16(:crypto.hash(:sha256, seeded), case: :lower) == sha

    # secret-free: the workspace's secret, the run's credential, an unregistered token
    refute seeded =~ @workspace_secret
    refute seeded =~ @oauth
    refute seeded =~ @unregistered
    assert seeded =~ "[REDACTED]"
    assert seeded =~ "ok, carrying on"

    # still a transcript `claude --resume` can read: one JSON object per line
    for line <- String.split(seeded, "\n", trim: true),
        do: assert({:ok, %{}} = Jason.decode(line))

    # the bytes go over HTTPS, not the channel
    refute Jason.encode!(spec) =~ "carrying on"
  end

  test "an argv that resumes nothing seeds nothing", ctx do
    prior_transcript!(ctx, [%{"type" => "user", "message" => "hi"}])

    assert {:ok, spec} =
             ContainerSpawn.remote_spec(ctx.request, %{argv: ["claude", "--print"], env: []}, "r")

    refute Map.has_key?(config_mount(spec), "session")
    assert Path.wildcard(Path.join(ctx.request.config_dir, "projects/**/*.jsonl")) == []
  end

  test "a session nobody holds is not seeded: the CLI reports it as it would locally", ctx do
    assert {:ok, spec} = ContainerSpawn.remote_spec(ctx.request, resume_args(), "run-1")
    refute Map.has_key?(config_mount(spec), "session")
  end

  test "a run with no checkout to fetch it through is not seeded", ctx do
    prior_transcript!(ctx, [%{"type" => "user", "message" => "hi"}])
    request = %{ctx.request | checkout: nil}

    assert {:ok, spec} = ContainerSpawn.remote_spec(request, resume_args(), "run-1")
    refute Map.has_key?(config_mount(spec), "session")
  end

  # A re-open of the same run: the copy already in its config dir (the earlier seed, or
  # the node's own upload since) is what the node is pointed at, untouched.
  test "a copy already in the run's config dir is used as it is", ctx do
    prior_transcript!(ctx, [%{"type" => "user", "message" => "older"}])
    slug = ClaudeSessionFile.project_slug(ctx.request.worktree)
    dest = Path.join([ctx.request.config_dir, "projects", slug, @sid <> ".jsonl"])
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, ~s({"type":"user","message":"newer, from the node"}\n))

    assert {:ok, spec} = ContainerSpawn.remote_spec(ctx.request, resume_args(), "run-1")

    assert config_mount(spec)["session"]["sha256"] ==
             Base.encode16(:crypto.hash(:sha256, File.read!(dest)), case: :lower)

    assert File.read!(dest) =~ "newer, from the node"
  end

  # What is read here goes to another machine: a link at the session's path is never
  # followed (it could name any file the primary can read).
  test "a link at the session's path is not read or seeded through", ctx do
    prior_transcript!(ctx, [%{"type" => "user", "message" => "hi"}])
    slug = ClaudeSessionFile.project_slug(ctx.request.worktree)
    dest = Path.join([ctx.request.config_dir, "projects", slug, @sid <> ".jsonl"])
    File.mkdir_p!(Path.dirname(dest))
    target = Path.join(ctx.base, "primary-only.txt")
    File.write!(target, "a file the node must never see\n")
    File.ln_s!(target, dest)

    assert {:ok, spec} = ContainerSpawn.remote_spec(ctx.request, resume_args(), "run-1")

    refute Map.has_key?(config_mount(spec), "session")
    assert File.read!(target) == "a file the node must never see\n"
  end

  # The first open of a session resume runs the resumed argv (a terse continue prompt,
  # inline); the original prompt file it replaced may be gone by a later re-open.
  test "prompt mounts follow the argv being run, not the one the run was prepared with", ctx do
    request = %{ctx.request | prompt_paths: [Path.join(ctx.base, "gone-prompt.txt")]}
    assert {:ok, spec} = ContainerSpawn.remote_spec(request, resume_args(), "run-1")
    refute Enum.any?(spec["mounts"], &(&1["kind"] == "prompt"))
  end

  test "checkout_context/2 names the seeded session for the node's fetch", ctx do
    prior_transcript!(ctx, [%{"type" => "user", "message" => "hi"}])
    {:ok, spec} = ContainerSpawn.remote_spec(ctx.request, resume_args(), "run-1")

    assert %{session: path, branch: "arbiter/x"} =
             ContainerSpawn.checkout_context(ctx.request, spec)

    assert path == config_mount(spec)["session"]["path"]
    assert ContainerSpawn.checkout_context(%{ctx.request | checkout: nil}, spec) == nil
  end
end
