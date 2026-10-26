defmodule ArbiterWeb.RemoteGitCredentialTest do
  @moduledoc """
  bd-akp9ae, end to end across the real halves (as `ArbiterWeb.RemoteRunTest`): a run
  placed on a node with its repo's scoped git credential, driven through a real
  `Arbiter.Worker` and `ClaudeSession.start/1` with `node:` set, the real node channel
  and the real agent running a stand-in `podman`.

    * An implementer of a GitHub App repo is pushed for by the host (bd-bsmkfu): its
      container holds no credential, so nothing it is sent carries a token, and the
      App's private key is nowhere in it. `Worker.Dispatch` places it on the node, and
      once it is done the host pushes the commit it made there and opens its PR, both
      with the App's installation token, minted on the primary.
    * A ReviewGate fix round on a GitHub App repo pushes from its own container: it
      takes the App's short-lived installation token, minted on the primary for the
      one repo, and only that. The token reaches the container through the node's
      per-run tmpfs file, never argv, `podman`'s persisted config or the node's disk;
      the file is gone when the run ends (success, failure or interrupt), and the
      token is revoked when the run's worker ends.
    * A deploy key never leaves the primary: such a spawn is refused on a node.
  """
  use ArbiterWeb.ChannelCase, async: false

  @moduletag :tmp_dir
  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Mergers.Github
  alias Arbiter.NodeAgent.{Config, Connection, Run, Runs, Secrets, Status}
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{RateLimit, Registry}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

  alias Arbiter.Worker.{
    BranchNamer,
    ClaudeSession,
    Dispatch,
    GitCredential,
    HostCredential,
    Watchdog
  }

  alias ArbiterWeb.{NodeTestEndpoint, StubPodman}

  @version "1.2.3"
  @oauth "sk-ant-oat01-GITCREDMARKER-77d"
  @app_token "ghs_NODECARRIEDMARKER0123456789"
  @http Arbiter.Worker.GitCredential.HTTP

  setup %{tmp_dir: tmp_dir} do
    # Short, comma-free: `Container` refuses a mount path with `,` or `:`.
    root = Path.join(System.tmp_dir!(), "rgc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    ArbiterWeb.NodeFixtures.use_data_home!(Path.join(tmp_dir, "data"))
    put_env_restoring(:arbiter, :node_primary_version, @version)
    put_env_restoring(:arbiter_web, :node_session_opts, tick_ms: :infinity)
    put_env_restoring(:arbiter, :worker_container_available, true)
    put_env_restoring(:arbiter, :worker_container_network_available, true)
    put_env_restoring(:arbiter, :git_credential_req_options, plug: {Req.Test, @http})
    RateLimit.reset()
    on_exit(&RateLimit.reset/0)

    on_exit(fn ->
      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    # The forge: the mint (the primary signs a JWT with the App's key and gets an
    # installation token back) and the revoke, each reported to the test.
    Req.Test.set_req_test_to_shared(%{async: false})
    test = self()

    Req.Test.stub(@http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case conn.method do
        "POST" ->
          send(test, {:mint, conn.request_path, Jason.decode!(body)})

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"token" => @app_token, "expires_at" => "2099-01-01T00:00:00Z"})

        "DELETE" ->
          send(
            test,
            {:revoke, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")}
          )

          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())
    NodeTestEndpoint.configure()
    start_supervised!(NodeTestEndpoint)

    {:ok, %{token: join}} = Nodes.mint_join_token([name: "cred-node"], "operator:test")
    {:ok, %{node: node, credential: credential}} = Nodes.redeem_join_token(join)

    stub = Path.join(root, "stub")
    podman = StubPodman.install(stub)
    home = Path.join(root, "node-home")
    rt = Path.join(root, "rt")
    File.mkdir_p!(home)
    File.mkdir_p!(rt)
    cli = Path.join(root, "claude")
    File.write!(cli, "#!/bin/sh\n")
    File.chmod!(cli, 0o755)

    {:ok, config} =
      Config.load(
        env: %{},
        primary_url: "http://127.0.0.1:#{NodeTestEndpoint.port()}",
        node_home: home,
        read_credential: fn _ -> {:ok, credential} end,
        version: @version,
        hb_interval_ms: 200,
        fence_after_ms: 60_000,
        backoff: [base: 20, max: 80],
        readiness_fun: fn -> %{ready: true, installed: true, checks: []} end,
        live_runs_fun: &Runs.inventory/0,
        run_opts: [
          podman: podman,
          runtime_dir: rt,
          require_tmpfs: false,
          image_fun: fn _image, _opts -> :ok end,
          files_fun: fn _sha, _name -> {:ok, cli} end,
          delegated_fun: fn -> ["memory", "pids", "cpu"] end,
          bridges_fun: fn _run, bridges -> {:ok, Enum.map(bridges, fn _ -> cli end)} end
        ]
      )

    start_supervised!({Task.Supervisor, name: Arbiter.NodeAgent.TaskSupervisor})
    start_supervised!({Status, path: config.status_path})
    for spec <- Runs.child_specs(), do: start_supervised!(spec)
    start_supervised!({Connection, config: config})

    assert_receive {:node_state, id, :online}, 10_000
    assert id == node.id

    pem = rsa_pem()

    %{node: node, stub: stub, rt: rt, home: home, cli: cli, root: root, pem: pem}
  end

  defp put_env_restoring(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(app, key, v)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  defp rsa_pem do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
  end

  # The App's private key material, line by line: a key that left the primary in
  # any encoding of its PEM body would carry these.
  defp key_lines(pem) do
    pem
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "-----"))
  end

  defp app_workspace!(pem) do
    workspace!(
      %{
        "kind" => "github_app",
        "app_id" => "42",
        "installation_id" => "7",
        "private_key_secret" => "APP_KEY",
        "remote" => "acme/tonic"
      },
      %{"APP_KEY" => pem}
    )
  end

  defp workspace!(entry, secrets, attrs \\ %{}) do
    {:ok, ws} =
      Ash.create(
        Workspace,
        Map.merge(
          %{
            name: "rgc-#{System.unique_integer([:positive])}",
            prefix: "rgc",
            config: %{"git_credentials" => %{"repos" => %{"tonic" => entry}}},
            secrets: secrets
          },
          attrs
        )
      )

    ws
  end

  defp worker!(ws) do
    {:ok, issue} =
      Ash.create(Issue, %{title: "credential carry", workspace_id: ws.id, issue_type: :feature})

    {:ok, pid} = Worker.start(task_id: issue.id, repo: "tonic", workspace_id: ws.id)
    Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:" <> issue.id)
    {issue.id, pid}
  end

  # `ClaudeSession.start/1` as a podman spawn placed on the node, with `plan` as the
  # spawn's git credential (what Dispatch or the ReviewGate would hand it).
  defp start_on_node(ctx, pid, task_id, plan) do
    sockets = Path.join(ctx.root, "sockets-#{System.unique_integer([:positive])}")
    File.mkdir_p!(sockets)
    proxy = Path.join(sockets, "proxy.sock")
    bridge = Path.join(sockets, "arb.sock")
    File.write!(proxy, "")
    File.write!(bridge, "")
    port = 38_100 + rem(System.unique_integer([:positive]), 800)

    egress = fn _opts ->
      {:ok, [proxy_socket: proxy, proxy_port: port, bridges: [{port + 1, bridge}]], "rtest"}
    end

    worktree = Path.join(ctx.root, "clone")
    File.mkdir_p!(worktree)

    ClaudeSession.start(
      owner: pid,
      worktree_path: worktree,
      command: ["sh", "-c", ~s(exec "$@" < /dev/null), "sh", "/opt/arbiter/cli/claude", "--print"],
      env: [{"CLAUDE_CODE_OAUTH_TOKEN", @oauth}, {"ARB_WORKER_BEAD_ID", task_id}],
      security:
        SecurityPolicy.merge(SecurityPolicy.base(), %{"sandbox" => %{"backend" => "podman"}}),
      provider: "claude",
      image: "localhost/arbiter-dev/beam:abc123",
      egress: egress,
      arb_token: "arb-tok",
      node: %{id: ctx.node.id, capacity: %{"mem_total" => 8 * 1024 * 1024 * 1024}},
      git_credential: plan
    )
  end

  # What the node holds of the live run: its validated spec, exactly as received.
  defp node_spec do
    assert_eventually(fn -> Runs.run_ids() != [] end)
    [run] = Runs.run_ids()
    :sys.get_state(GenServer.whereis(Run.via(run))).spec
  end

  # Everything the node wrote, recorded or kept: the stand-in podman's records (argv,
  # client env, podman's persisted config, the secrets file as mounted), the node's
  # home (run dirs, status) and its runtime dir (the secrets root).
  defp node_side(ctx) do
    recorded =
      ctx.stub
      |> files_under()
      |> Enum.reject(&(Path.basename(&1) == "podman"))
      |> Enum.map_join("\n", &File.read!/1)

    recorded <> "\n" <> node_disk_after_run(ctx)
  end

  defp node_disk_after_run(ctx),
    do: [ctx.home, ctx.rt] |> Enum.flat_map(&files_under/1) |> Enum.map_join("\n", &File.read!/1)

  defp files_under(dir),
    do: dir |> Path.join("**") |> Path.wildcard(match_dot: true) |> Enum.filter(&File.regular?/1)

  # Every log line of every process, at every level, while `fun` runs (the suite logs
  # at :warning; this module is not async, so nothing else runs meanwhile). Asserted
  # non-empty, so a "the token is not in the log" check is never vacuous.
  defp capture_all(fun) do
    level = Logger.level()
    Logger.configure(level: :debug)

    log =
      try do
        capture_log([level: :debug], fun)
      after
        Logger.configure(level: level)
      end

    assert log != "", "nothing was logged: the log assertions would prove nothing"
    log
  end

  defp stop_worker(pid) do
    ref = Process.monitor(pid)
    GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end

  describe "an implementer of a GitHub App repo (the host pushes its branch)" do
    test "is handed no credential: nothing sent to the node carries a token or the App's key",
         ctx do
      ws = app_workspace!(ctx.pem)
      {task_id, pid} = worker!(ws)
      StubPodman.write_mode(ctx.stub, "hang")

      {:ok, plan} =
        GitCredential.plan(ws, "tonic", role: :implementer, host_pushes?: true)

      log =
        capture_all(fn ->
          assert {:ok, {:remote, _}} = start_on_node(ctx, pid, task_id, plan)
          assert_receive {:worker_output, ^task_id, "line-1"}, 10_000

          spec = node_spec()
          refute Map.has_key?(spec.secrets, "ARB_GIT_TOKEN")
          sent = inspect(spec, limit: :infinity, printable_limit: :infinity)
          seen = node_side(ctx)

          for line <- key_lines(ctx.pem) do
            refute sent =~ line
            refute seen =~ line
          end

          refute sent =~ "ghs_"
          refute seen =~ "ghs_"
          stop_worker(pid)
        end)

      # The host mints for its own push and PR, never for this spawn.
      refute_received {:mint, _, _}
      refute_received {:revoke, _, _}
      for line <- key_lines(ctx.pem), do: refute(log =~ line)
    end

    # The operator also exposed the App's key to workers as an env var. A local run
    # would get it; a run on a node is sent without it: the key never leaves.
    test "a workspace that also exposes the App's key as a worker env var sends none of it",
         ctx do
      ws =
        workspace!(
          %{
            "kind" => "github_app",
            "app_id" => "42",
            "installation_id" => "7",
            "private_key_secret" => "APP_KEY",
            "remote" => "acme/tonic"
          },
          %{"APP_KEY" => ctx.pem},
          %{worker_env: %{"APP_PEM" => %{"value" => ctx.pem, "secret" => true}}}
        )

      {task_id, pid} = worker!(ws)
      StubPodman.write_mode(ctx.stub, "hang")
      {:ok, plan} = GitCredential.plan(ws, "tonic", role: :implementer, host_pushes?: true)

      log =
        capture_all(fn ->
          assert {:ok, {:remote, _}} = start_on_node(ctx, pid, task_id, plan)
          assert_receive {:worker_output, ^task_id, "line-1"}, 10_000

          spec = node_spec()
          refute Map.has_key?(spec.secrets, "APP_PEM")
          refute Map.has_key?(spec.env, "APP_PEM")
          sent = inspect(spec, limit: :infinity, printable_limit: :infinity)
          seen = node_side(ctx)

          for line <- key_lines(ctx.pem) do
            refute sent =~ line
            refute seen =~ line
          end

          stop_worker(pid)
        end)

      # The var was there to send, and was held back by name.
      assert log =~ "not sending APP_PEM to the node"
      for line <- key_lines(ctx.pem), do: refute(log =~ line)
    end
  end

  # The production path: `Worker.Dispatch.dispatch/2` itself places a GitHub App repo's
  # implementer on the node under `prefer_remote` (bd-21r811 kept it on the primary),
  # provisions its private clone, and hands the run to the node through
  # `ClaudeSession`: what the node holds of it carries neither a token nor the App's key.
  # When the run is done, the host pushes its branch and opens its PR as the App.
  describe "Worker.Dispatch.dispatch/2 of a GitHub App repo's implementer" do
    # The repo's key is its GitHub slug, which the PR is opened on.
    @repo "acme/app-repo"

    setup ctx do
      repo = Path.join(ctx.root, "repo")
      File.mkdir_p!(Path.join(repo, "lib"))
      git!(repo, ["init", "-q", "-b", "main"])
      git!(repo, ["config", "user.email", "t@e.com"])
      git!(repo, ["config", "user.name", "T"])
      git!(repo, ["config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "lib/a.txt"), "a\n")
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-q", "-m", "base"])
      forge = Path.join(ctx.root, "forge.git")
      git!(ctx.root, ["init", "-q", "--bare", "-b", "main", forge])
      git!(repo, ["remote", "add", "origin", forge])
      git!(repo, ["push", "-q", "origin", "main"])

      put_env_restoring(:arbiter, :repo_paths, %{@repo => repo})
      put_env_restoring(:arbiter, :worktree_root, Path.join(ctx.root, "wt"))
      put_env_restoring(:arbiter, :output_log_root, Path.join(ctx.root, "logs"))
      put_env_restoring(:arbiter, :worker_deps_cache, false)

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rgc-#{System.unique_integer([:positive])}",
          prefix: "rgd#{System.unique_integer([:positive])}",
          config: %{
            "worker" => %{"placement" => "prefer_remote"},
            "agent" => %{"security" => %{"sandbox" => %{"backend" => "podman"}}},
            # The PR opens on GitHub (`Mergers.Github`, stubbed), where a github_app
            # repo is opened with the App's token, never this operator token.
            "merge" => %{
              "strategy" => "github",
              "config" => %{"credentials_ref" => "operator-classic-token"}
            },
            "git_credentials" => %{
              "repos" => %{
                @repo => %{
                  "kind" => "github_app",
                  "app_id" => "42",
                  "installation_id" => "7",
                  "private_key_secret" => "APP_KEY",
                  "remote" => "acme/app-repo"
                }
              }
            }
          },
          secrets: %{"APP_KEY" => ctx.pem}
        })

      {:ok, created} =
        Ash.create(Issue, %{
          title: "implement on a node",
          workspace_id: ws.id,
          acceptance: "- runs on the node"
        })

      {:ok, issue} = Ash.update(created, %{}, action: :promote_to_ready)
      %{dispatch_ws: ws, dispatch_issue: issue, forge: forge}
    end

    test "is placed on the node and runs there handed no credential", ctx do
      StubPodman.write_mode(ctx.stub, "hang")

      log =
        capture_all(fn ->
          assert {:ok, %{worker_pid: pid}} = dispatch_to_node(ctx)

          # Placed on the node, not the primary.
          assert placed_node(pid) == ctx.node.id

          # The run on the node: its spec as the node received it, and everything the
          # node recorded or wrote.
          spec = node_spec()
          refute Map.has_key?(spec.secrets, "ARB_GIT_TOKEN")
          sent = inspect(spec, limit: :infinity, printable_limit: :infinity)
          seen = node_side(ctx)
          refute sent =~ "ghs_"

          for line <- key_lines(ctx.pem) do
            refute sent =~ line
            refute seen =~ line
          end

          stop_worker(pid)
        end)

      # Nothing was minted for the run: the host mints only for its own push and PR.
      refute_received {:mint, _, _}
      for line <- key_lines(ctx.pem), do: refute(log =~ line)
    end

    # AC1 end to end: the agent commits on the node and says `arb done`; the node's last
    # upload brings the commit into the home clone, and the host pushes the branch and
    # opens the PR with the App's installation token, minted here for the one repo. The
    # node is handed neither that token nor the App's key.
    test "the host pushes the commit made on the node and opens the PR as the App", ctx do
      issue = ctx.dispatch_issue
      task_id = issue.id
      put_env_restoring(:arbiter, :host_credential_req_options, plug: {Req.Test, @http})
      HostCredential.Cache.clear()
      on_exit(&HostCredential.Cache.clear/0)
      on_exit(fn -> stop_watchdog(task_id) end)
      test = self()

      Req.Test.stub(Github.HTTP, fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        send(test, {:github, conn.method, conn.request_path, auth})

        case {conn.method, conn.request_path} do
          {"GET", "/repos/acme/app-repo/pulls"} ->
            Req.Test.json(conn, [])

          {"POST", "/repos/acme/app-repo/pulls"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 812})

          _ ->
            conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
        end
      end)

      # The agent's work, in its shadow clone on the node.
      File.write!(Path.join(ctx.stub, "agent_script"), ~S"""
      cd "$1" || exit 1
      printf 'done on the node\n' > node.txt
      git add node.txt
      git -c user.name=agent -c user.email=agent@example.com -c commit.gpgsign=false \
        commit -q -m "work on the node"
      git rev-parse HEAD > "$(dirname "$0")/node.head"
      """)

      # What a push reaches the forge with: `receive-pack` inherits the pusher's env.
      push_env = Path.join(ctx.root, "push.env")
      hook = Path.join([ctx.forge, "hooks", "pre-receive"])
      File.write!(hook, "#!/bin/sh\ncat > /dev/null\nenv > '#{push_env}'\n")
      File.chmod!(hook, 0o755)

      StubPodman.write_mode(ctx.stub, "slow")
      Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:" <> task_id)

      log =
        capture_all(fn ->
          assert {:ok, %{worker_pid: pid}} = dispatch_to_node(ctx)
          ref = Process.monitor(pid)
          assert placed_node(pid) == ctx.node.id
          assert_receive {:worker_output, ^task_id, "line-1"}, 10_000

          spec = node_spec()
          refute Map.has_key?(spec.secrets, "ARB_GIT_TOKEN")
          sent = inspect(spec, limit: :infinity, printable_limit: :infinity)
          refute sent =~ "ghs_"
          for line <- key_lines(ctx.pem), do: refute(sent =~ line)

          # The agent prints `arb done` (`ClaudeSession` tells its Worker so) and its
          # container exits; the node's last upload precedes the exit.
          send(pid, {:__claude_session_done__, "arb done"})
          _ = :sys.get_state(pid)
          File.write!(Path.join(ctx.stub, "go"), "")

          # Opening the PR ends the run.
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 30_000
          stop_watchdog(task_id)
        end)

      head = ctx.stub |> Path.join("node.head") |> File.read!() |> String.trim()
      branch = BranchNamer.derive(issue)

      # Pushed: the forge's branch is the commit made on the node...
      assert git_out(ctx.forge, ["rev-parse", "refs/heads/" <> branch]) == head

      # ...with the App's installation token, minted on the primary for the one repo...
      assert_received {:mint, "/app/installations/7/access_tokens", body}
      assert body["repositories"] == ["app-repo"]
      assert body["permissions"]["contents"] == "write"
      assert File.read!(push_env) =~ "ARB_GIT_TOKEN=" <> @app_token

      # ...and the PR is opened with it, so the App bot is its author.
      assert_received {:github, "POST", "/repos/acme/app-repo/pulls", ["Bearer " <> @app_token]}
      refute_received {:github, _, _, ["Bearer operator-classic-token"]}
      assert %{state: :merging, pr_ref: pr_ref} = Ash.get!(Issue, task_id)
      assert pr_ref =~ "812"

      # The node was handed neither the token nor the key, and the log names neither.
      seen = node_side(ctx)
      refute seen =~ @app_token
      refute log =~ @app_token

      for line <- key_lines(ctx.pem) do
        refute seen =~ line
        refute log =~ line
      end
    end
  end

  # `Worker.Dispatch.dispatch/2` of the describe's ticket, with the node as the one
  # placement may choose.
  defp dispatch_to_node(ctx) do
    row = %{
      id: ctx.node.id,
      name: "cred-node",
      state: :online,
      health: :ready,
      max: 2,
      live: 0,
      workspace_ids: [],
      labels: [],
      caps: %{}
    }

    sockets = Path.join(ctx.root, "dispatch-sockets")
    File.mkdir_p!(sockets)
    proxy = Path.join(sockets, "proxy.sock")
    bridge = Path.join(sockets, "arb.sock")
    File.write!(proxy, "")
    File.write!(bridge, "")

    egress = fn _opts ->
      {:ok, [proxy_socket: proxy, proxy_port: 38_061, bridges: [{38_062, bridge}]], "rtest"}
    end

    Dispatch.dispatch(ctx.dispatch_issue.id,
      repo: @repo,
      start_driver: false,
      start_claude: true,
      preflight: false,
      nodes: [row],
      image: "localhost/arbiter-dev/beam:abc123",
      egress: egress
    )
  end

  # The node a live dispatch was placed on (`nil`: the primary).
  defp placed_node(pid) do
    case Enum.find(Arbiter.Worker.Registry.live_dispatches(), &(&1.pid == pid)) do
      %{node_id: node_id} -> node_id
      nil -> flunk("no live dispatch for #{inspect(pid)}")
    end
  end

  defp stop_watchdog(task_id) do
    case Watchdog.whereis(task_id) do
      nil -> :ok
      pid -> Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.WatchdogSupervisor, pid)
    end
  end

  defp git_out(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    String.trim(out)
  end

  describe "a fix round of a GitHub App repo (it pushes from its container)" do
    setup ctx do
      ws = app_workspace!(ctx.pem)
      {task_id, pid} = worker!(ws)
      {:ok, plan} = GitCredential.plan(ws, "tonic", role: :implementer)
      assert %GitCredential{mode: :scoped, entry: %{kind: :github_app}} = plan
      %{ws: ws, task_id: task_id, pid: pid, plan: plan}
    end

    test "takes only the repo's installation token, through the tmpfs file, never the App's key",
         ctx do
      StubPodman.write_mode(ctx.stub, "hang")

      log =
        capture_all(fn ->
          assert {:ok, {:remote, _}} = start_on_node(ctx, ctx.pid, ctx.task_id, ctx.plan)
          assert_receive {:worker_output, _, "line-1"}, 10_000

          # Minted on the primary for the one repo, with a worker's push permissions.
          assert_receive {:mint, "/app/installations/7/access_tokens", body}
          assert body["repositories"] == ["tonic"]
          assert body["permissions"]["contents"] == "write"
          refute Map.has_key?(body["permissions"], "administration")

          # What the node received: the token as a secret, and nothing of the key.
          spec = node_spec()
          assert spec.secrets["ARB_GIT_TOKEN"] == @app_token
          refute inspect(spec.env) =~ @app_token
          refute inspect(spec.command) =~ @app_token
          assert spec.secrets["GIT_CONFIG_PARAMETERS"] =~ ~s([ "$p" = "acme/tonic" ])
          sent = inspect(spec, limit: :infinity, printable_limit: :infinity)
          for line <- key_lines(ctx.pem), do: refute(sent =~ line)

          # In the container through the tmpfs file only: not argv, not `-e`, not
          # what podman persists.
          assert File.read!(Path.join(ctx.stub, "secrets.seen")) =~ @app_token
          refute File.read!(Path.join(ctx.stub, "run.argv")) =~ @app_token
          refute File.read!(Path.join([ctx.stub, "graph", "config.json"])) =~ @app_token
          refute File.read!(Path.join(ctx.stub, "run.env")) =~ @app_token
          for line <- key_lines(ctx.pem), do: refute(node_side(ctx) =~ line)

          stop_worker(ctx.pid)
        end)

      refute log =~ @app_token
      for line <- key_lines(ctx.pem), do: refute(log =~ line)
    end

    test "success: the token leaves the node when the run exits, and is revoked when its worker ends",
         ctx do
      File.write!(Path.join(ctx.stub, "lines"), "2")
      task_id = ctx.task_id

      log =
        capture_all(fn ->
          assert {:ok, {:remote, _}} = start_on_node(ctx, ctx.pid, task_id, ctx.plan)
          assert_receive {:worker_exited, ^task_id, 0}, 10_000

          assert File.read!(Path.join(ctx.stub, "secrets.seen")) =~ @app_token
          assert_eventually(fn -> Secrets.runs(ctx.rt) == [] end)
          refute node_disk_after_run(ctx) =~ @app_token
          refute_received {:revoke, _, _}

          stop_worker(ctx.pid)
          assert_receive {:revoke, "/installation/token", ["Bearer " <> @app_token]}, 5_000
        end)

      refute log =~ @app_token
    end

    test "failure: the token leaves the node when the run fails, and is revoked when its worker ends",
         ctx do
      StubPodman.write_mode(ctx.stub, "oom")
      task_id = ctx.task_id

      log =
        capture_all(fn ->
          assert {:ok, {:remote, _}} = start_on_node(ctx, ctx.pid, task_id, ctx.plan)
          assert_receive {:worker_exited, ^task_id, 137}, 10_000

          assert File.read!(Path.join(ctx.stub, "secrets.seen")) =~ @app_token
          assert_eventually(fn -> Secrets.runs(ctx.rt) == [] end)
          refute node_disk_after_run(ctx) =~ @app_token

          stop_worker(ctx.pid)
          assert_receive {:revoke, "/installation/token", ["Bearer " <> @app_token]}, 5_000
        end)

      refute log =~ @app_token
    end

    test "interrupt: a worker killed mid-run takes the token off the node and revokes it", ctx do
      StubPodman.write_mode(ctx.stub, "hang")

      log =
        capture_all(fn ->
          assert {:ok, {:remote, _}} = start_on_node(ctx, ctx.pid, ctx.task_id, ctx.plan)
          assert_receive {:worker_output, _, "line-1"}, 10_000
          [run] = Secrets.runs(ctx.rt)
          assert File.read!(Secrets.file(ctx.rt, run)) =~ @app_token

          Process.exit(ctx.pid, :kill)

          # The session cancels the run: the agent removes the container and the file.
          assert_eventually(fn ->
            File.read!(Path.join(ctx.stub, "calls")) =~ "rm --force --ignore --time 0"
          end)

          assert_eventually(fn -> Secrets.runs(ctx.rt) == [] end)
          refute node_disk_after_run(ctx) =~ @app_token
          assert_receive {:revoke, "/installation/token", ["Bearer " <> @app_token]}, 5_000
        end)

      refute log =~ @app_token
    end
  end

  describe "a fix round of a deploy-key repo" do
    test "is refused on a node: the key never leaves the primary", ctx do
      key =
        "-----BEGIN OPENSSH PRIVATE KEY-----\nDEPLOYKEYMARKER0123456789\n" <>
          "-----END OPENSSH PRIVATE KEY-----\n"

      ws =
        workspace!(%{"kind" => "deploy_key", "key_secret" => "TONIC_KEY"}, %{"TONIC_KEY" => key})

      {task_id, pid} = worker!(ws)
      {:ok, plan} = GitCredential.plan(ws, "tonic", role: :implementer)

      assert {:error, {:git_credential_unsupported, :remote_node}} =
               start_on_node(ctx, pid, task_id, plan)

      refute File.exists?(Path.join(ctx.stub, "run.argv"))
      assert Runs.run_ids() == []
      refute node_side(ctx) =~ "DEPLOYKEYMARKER"
      stop_worker(pid)
    end
  end

  defp assert_eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never held")

      true ->
        receive do
        after
          50 -> assert_eventually(fun, tries - 1)
        end
    end
  end
end
