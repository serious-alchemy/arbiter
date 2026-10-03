defmodule ArbiterWeb.ContainerSpawnLiveTest do
  @moduledoc """
  bd-d2o3xb (P7): a Claude worker spawned under `sandbox.backend: podman`,
  against a REAL rootless podman, the REAL Arbiter endpoint (over a Bandit
  socket) and a REAL `Arbiter.Worker.Egress` run. The command is the
  `ClaudeSession` spawn path's own (`ContainerSpawn.wrap_port/1`); the CLI that
  runs inside is the host's real `claude` binary and real `arb` escript.

  Opt-in, because it builds a throwaway image (network, about a minute) and
  starts containers:

      cd apps/arbiter_web && mix test --include podman \\
        test/arbiter_web/container_spawn_live_test.exs

  The transcript of the run is printed. Every container is named `arb-…` and
  removed by that exact name; the image by its exact tag. Never a pattern kill:
  the coordinator runs on this host.
  """
  # async: false — Bandit's request processes share the sandbox connection.
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Worker.Egress.Event
  alias Arbiter.Worker.PrivateClone

  require Ash.Query

  @moduletag :podman
  @moduletag timeout: 600_000
  @base "docker.io/hexpm/elixir:1.19.4-erlang-28.2-debian-bookworm-20260112-slim"
  @branch "feature/bd-p7-live"

  @containerfile """
  FROM #{@base}
  RUN apt-get update \\
   && apt-get install -y --no-install-recommends socat git curl ca-certificates procps \\
   && rm -rf /var/lib/apt/lists/* \\
   && mkdir -p /opt/arbiter/cli
  ENV PATH=/opt/arbiter/cli:/usr/local/bin:/usr/bin:/bin
  """

  setup do
    for tool <- ~w(podman claude arb) do
      assert System.find_executable(tool), "#{tool} must be on PATH for this test"
    end

    {_, 0} = System.cmd("podman", ["image", "exists", @base])

    listener =
      start_supervised!(
        {Bandit, plug: ArbiterWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)

    previous_mcp = Application.get_env(:arbiter, Arbiter.MCP)
    Application.put_env(:arbiter, Arbiter.MCP, url: "http://127.0.0.1:#{port}/mcp")

    root =
      Path.join(
        Arbiter.Config.Paths.scratch_root(),
        "p7live#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    previous_wt = Application.get_env(:arbiter, :worktree_root)
    Application.put_env(:arbiter, :worktree_root, Path.join(root, "worktrees"))

    for key <- [:worker_container_available, :worker_container_network_available] do
      Application.delete_env(:arbiter, key)
    end

    image = "localhost/arb-test/p7-live:#{System.unique_integer([:positive])}"
    build_image!(root, image)

    on_exit(fn ->
      System.cmd("podman", ["rmi", "--force", image], stderr_to_stdout: true)
      File.rm_rf(root)

      if previous_mcp,
        do: Application.put_env(:arbiter, Arbiter.MCP, previous_mcp),
        else: Application.delete_env(:arbiter, Arbiter.MCP)

      if previous_wt,
        do: Application.put_env(:arbiter, :worktree_root, previous_wt),
        else: Application.delete_env(:arbiter, :worktree_root)
    end)

    %{root: root, image: image, port: port}
  end

  defp build_image!(root, image) do
    dir = Path.join(root, "image")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "Containerfile"), @containerfile)

    case System.cmd("podman", ["build", "--pull=never", "-t", image, dir], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, status} -> flunk("image build failed (#{status}):\n#{out}")
    end
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    String.trim(out)
  end

  defp private_clone!(root) do
    forge = Path.join(root, "forge.git")
    seed = Path.join(root, "seed")
    checkout = Path.join(root, "checkout")
    File.mkdir_p!(seed)
    git!(root, ["init", "-q", "--bare", "-b", "main", forge])
    git!(root, ["init", "-q", "-b", "main", seed])
    File.write!(Path.join(seed, "README.md"), "readme\n")
    git!(seed, ["add", "."])
    git!(seed, ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"])
    git!(seed, ["remote", "add", "origin", forge])
    git!(seed, ["push", "-q", "origin", "main"])
    git!(root, ["clone", "-q", forge, checkout])
    {:ok, clone} = PrivateClone.create(checkout, @branch, "main")
    clone
  end

  test "claude under podman: only the allowlist, the bridges and the clone; MCP and arb through the bridge",
       ctx do
    n = System.unique_integer([:positive])

    ws =
      Ash.create!(Workspace, %{name: "p7live-#{n}", prefix: "pl#{n}", config: %{}})

    task = Ash.create!(Issue, %{title: "p7 live", workspace_id: ws.id})
    other_ws = Ash.create!(Workspace, %{name: "p7other-#{n}", prefix: "po#{n}", config: %{}})
    foreign = Ash.create!(Issue, %{title: "someone else", workspace_id: other_ws.id})
    clone = private_clone!(ctx.root)

    # The same call a dispatch makes: a worker token for this task, and the
    # `.mcp.json` that carries it, written into the clone.
    mcp = Dispatch.inject_mcp_config(task, clone, repo: nil)
    assert File.regular?(Path.join(clone, ".mcp.json"))
    token = Keyword.fetch!(mcp, :arb_token)

    {:ok, pid} = Worker.start(task_id: task.id, repo: "arbiter")
    Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:" <> task.id)

    policy =
      SecurityPolicy.merge(SecurityPolicy.base(), %{"sandbox" => %{"backend" => "podman"}})

    home = System.user_home!()

    script = """
    echo "== identity"
    echo "uid=$(id -u) home=$HOME cwd=$PWD"
    echo "== host paths visible?"
    for p in #{home}/.ssh #{home}/.arbiter #{home}/.claude /run/user /root/.ssh /etc/machine-id; do
      if [ -e "$p" ]; then echo "VISIBLE $p"; else echo "absent  $p"; fi
    done
    echo "== environment (names only)"
    env | cut -d= -f1 | sort | tr '\\n' ' '; echo
    echo "== interfaces"
    ls /sys/class/net | tr '\\n' ' '; echo
    echo "== direct egress, no proxy (must fail)"
    curl -sS -m 6 --noproxy '*' -o /dev/null -w 'status=%{http_code}\\n' https://api.anthropic.com/ 2>&1 | tail -1
    echo "== egress through the proxy bridge (learn mode: allowed and logged)"
    curl -sS -m 30 -o /dev/null -w 'api.anthropic.com status=%{http_code}\\n' https://api.anthropic.com/ 2>&1 | tail -1
    curl -sS -m 30 -o /dev/null -w 'example.org status=%{http_code}\\n' https://example.org/ 2>&1 | tail -1
    echo "== claude (the host's binary, mounted read-only)"
    claude --version
    echo "== MCP through the Arbiter bridge: initialize with the worker token"
    curl -sS -m 20 -X POST "$ARB_HOST/mcp" \\
      -H "authorization: Bearer $ARB_TOKEN" -H 'content-type: application/json' \\
      -H 'accept: application/json, text/event-stream' \\
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"p7","version":"1"}}}' \\
      -o /dev/null -w 'mcp initialize status=%{http_code}\\n'
    echo "== REST through the Arbiter bridge: the identity is the worker's own (G9), not the header's"
    curl -sS -m 20 -o /dev/null -w 'own task, no header status=%{http_code}\n' "$ARB_HOST/api/issues/$ARB_WORKER_BEAD_ID"
    curl -sS -m 20 -o /dev/null -w 'other workspace status=%{http_code}\n' "$ARB_HOST/api/issues/#{foreign.id}"
    echo "== arb through the Arbiter bridge"
    arb ticket show $ARB_WORKER_BEAD_ID --json 2>&1 | grep -o '"id":"[^"]*"' | head -1
    echo "== claude mcp list (reads .mcp.json in the clone)"
    claude mcp list 2>&1 | head -5
    echo "== done"
    """

    assert {:ok, port} =
             ClaudeSession.start(
               [
                 owner: pid,
                 worktree_path: clone,
                 command: ["sh", "-c", script],
                 env: [],
                 security: policy,
                 provider: "claude",
                 image: ctx.image
               ] ++ Keyword.take(mcp, [:arb_token])
             )

    assert is_port(port)
    assert_receive {:worker_exited, _, status}, 240_000

    lines = collect([])
    IO.puts("\n---- container transcript (exit #{status}) ----")
    Enum.each(lines, &IO.puts/1)
    IO.puts("---- end ----")

    out = Enum.join(lines, "\n")
    assert status == 0

    # Files: only the clone, the run dirs and the CLIs.
    assert out =~ "absent  #{home}/.ssh"
    assert out =~ "absent  #{home}/.arbiter"
    assert out =~ "absent  #{home}/.claude"
    assert out =~ "absent  /run/user"
    assert out =~ "absent  /root/.ssh"
    refute out =~ "VISIBLE"
    {host_uid, 0} = System.cmd("id", ["-u"])
    assert out =~ "uid=#{String.trim(host_uid)} "

    # Env: the allowlist, no inherited host variables, the token's name only.
    [env_line] =
      Regex.run(~r/== environment \(names only\)\n(.*)\n/, out, capture: :all_but_first)

    names = String.split(env_line)

    for name <- ~w(ARB_TOKEN ARB_HOST ARB_WORKER_BEAD_ID HTTPS_PROXY CLAUDE_CONFIG_DIR HOME),
        do: assert(name in names)

    for name <-
          ~w(SSH_AUTH_SOCK DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR ARBITER_CLOAK_KEY SECRET_KEY_BASE),
        do: refute(name in names)

    refute out =~ token

    # Network: lo only, direct egress fails, the proxy bridge works.
    assert out =~ ~r/== interfaces\nlo\s*\n/
    assert out =~ ~r/direct egress, no proxy \(must fail\)\nstatus=000/
    assert out =~ ~r/api\.anthropic\.com status=[1-5]\d\d/
    assert out =~ ~r/example\.org status=[1-5]\d\d/

    # MCP and arb through the Arbiter bridge, as this worker.
    assert out =~ "mcp initialize status=200"
    assert out =~ "own task, no header status=200"
    refute out =~ "other workspace status=200"
    assert out =~ ~r/other workspace status=(401|403|404)/
    assert out =~ ~s("id":"#{task.id}")

    # The proxy decided and logged: learn mode allows and records.
    events =
      Event
      |> Ash.Query.filter(task_id == ^task.id)
      |> Ash.read!()

    IO.puts("---- egress_events for #{task.id} ----")

    for e <- events,
        do: IO.puts("#{e.mode} #{e.decision} (policy #{e.policy_verdict}) #{e.host}:#{e.port}")

    IO.puts("---- end ----")

    assert Enum.any?(events, &(&1.host == "api.anthropic.com" and &1.decision == :allow))
    assert Enum.any?(events, &(&1.host == "example.org" and &1.mode == :learn))

    # Stopping the worker removes the container by name; nothing is left.
    %{sandbox: %{name: name}} = Worker.state(pid).meta.claude_spawn
    GenServer.stop(pid, :normal)
    refute match?({_, 0}, System.cmd("podman", ["container", "exists", name]))
  end

  defp collect(acc) do
    receive do
      {:worker_output, _, line} -> collect([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
