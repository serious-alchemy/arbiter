defmodule ArbiterWeb.NodeJoinScriptRunTest do
  @moduledoc """
  Runs the real join script (`docs/design/remote-workers.md` §5.5) with bash,
  real `curl`/`tar`/`sha256sum`, against the real endpoint served by Bandit on a
  loopback socket. Only the host-inspecting tools (`uname`, `podman`,
  `loginctl`, `systemctl`, ...) are stubs, so each scenario can be a machine
  that passes or fails a given prerequisite; every stub appends its argv to one
  log, which is how these tests prove what was and was not executed.

  async: false — Bandit's request processes share the sandbox connection.
  """
  use ArbiterWeb.ConnCase, async: false

  import ArbiterWeb.NodeFixtures

  alias Arbiter.Actor
  alias Arbiter.Nodes
  alias Arbiter.Nodes.RateLimit

  @moduletag :tmp_dir
  @operator Actor.operator("cli")

  @stubs %{
    "uname" => ~S"""
    case "$1" in
      -s) echo Linux ;;
      -m) echo "${FAKE_ARCH:-x86_64}" ;;
      *) echo Linux ;;
    esac
    """,
    "getconf" => ~S"""
    echo "glibc ${FAKE_GLIBC:-2.34}"
    """,
    "id" => ~S"""
    case "$1" in
      -u) echo "${FAKE_UID:-1000}" ;;
      -un) echo tester ;;
      *) echo "uid=${FAKE_UID:-1000}(tester)" ;;
    esac
    """,
    "stat" => ~S"""
    if [ "$1" = "-fc" ]; then echo "${FAKE_CGROUP_FS:-cgroup2fs}"; exit 0; fi
    exec "$REAL_STAT" "$@"
    """,
    "df" => ~S"""
    echo "Filesystem 1024-blocks Used Available Capacity Mounted"
    echo "fake 999999999 1 ${FAKE_DISK_KB:-999999999} 1% /"
    """,
    "git" => "exit 0\n",
    "podman" => ~S"""
    case "$1" in
      --version) echo "podman version ${FAKE_PODMAN:-5.8.7}" ;;
      info) echo true ;;
      *) ;;
    esac
    """,
    "loginctl" => ~S"""
    case "$1" in
      show-user) echo "${FAKE_LINGER:-yes}" ;;
      --no-ask-password) exit "${FAKE_LINGER_FIX_RC:-0}" ;;
      *) ;;
    esac
    """,
    "systemctl" => ~S"""
    exit 0
    """,
    "sudo" => ~S"""
    echo "SUDO WAS EXECUTED" >> "$STUB_LOG"
    exit 1
    """
  }

  @stub_prologue ~S"""
  #!/bin/sh
  printf '%s %s\n' "$(basename "$0")" "$*" >> "$STUB_LOG"
  if [ -n "${ARB_JOIN_TOKEN:-}" ]; then echo "LEAK: $(basename "$0") inherited ARB_JOIN_TOKEN" >> "$STUB_LOG"; fi
  """

  @curl_wrapper ~S"""
  #!/bin/sh
  printf 'curl %s\n' "$*" >> "$STUB_LOG"
  if [ -n "${ARB_JOIN_TOKEN:-}" ]; then echo "LEAK: curl inherited ARB_JOIN_TOKEN" >> "$STUB_LOG"; fi
  "$REAL_CURL" "$@"
  rc=$?
  if [ -n "${FAKE_CORRUPT:-}" ]; then
    case "$*" in
      */nodes/agent/*)
        prev=""
        for a in "$@"; do
          if [ "$prev" = "-o" ]; then echo junk >> "$a"; fi
          prev="$a"
        done
        ;;
    esac
  fi
  exit $rc
  """

  setup %{tmp_dir: tmp} do
    RateLimit.reset()
    release = install_release!(Path.join(tmp, "data"))
    use_data_home!(Path.join(tmp, "data"))

    listener =
      start_supervised!(
        {Bandit, plug: ArbiterWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(listener)
    url = "http://127.0.0.1:#{port}"
    {:ok, _} = Arbiter.Settings.set_nodes_public_url(url)
    on_exit(fn -> Arbiter.Settings.set_nodes_public_url(nil) end)

    bin = Path.join(tmp, "bin")
    home = Path.join(tmp, "home")
    run = Path.join(tmp, "run")
    fsroot = Path.join(tmp, "fsroot")
    log = Path.join(tmp, "stub.log")
    for d <- [bin, home, run], do: File.mkdir_p!(d)
    File.chmod!(run, 0o700)
    File.write!(log, "")

    for {name, body} <- @stubs, do: write_exec(Path.join(bin, name), @stub_prologue <> body)
    write_exec(Path.join(bin, "curl"), @curl_wrapper)

    fixture_fs(fsroot, "1000")

    {:ok,
     url: url,
     release: release,
     bin: bin,
     home: home,
     run: run,
     fsroot: fsroot,
     log: log,
     script: fetch_script(url, tmp)}
  end

  defp write_exec(path, body) do
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  # A machine whose subid ranges and cgroup delegation are fine.
  defp fixture_fs(root, uid) do
    File.mkdir_p!(Path.join(root, "etc"))
    File.write!(Path.join(root, "etc/subuid"), "tester:100000:65536\nother:1:1\n")
    File.write!(Path.join(root, "etc/subgid"), "tester:100000:65536\n")
    base = Path.join(root, "sys/fs/cgroup/user.slice/user-#{uid}.slice/user@#{uid}.service")
    File.mkdir_p!(base)
    File.write!(Path.join(base, "cgroup.controllers"), "cpu io memory pids\n")
    File.write!(Path.join(base, "cgroup.subtree_control"), "cpu io memory pids\n")
  end

  # Fetch the script the way a node does: GET /nodes/join over real HTTP.
  defp fetch_script(url, tmp) do
    path = Path.join(tmp, "join.sh")
    {_, 0} = System.cmd("curl", ["-fsS", "-o", path, url <> "/nodes/join"])
    path
  end

  defp token_file(ctx, token) do
    path = Path.join(Path.dirname(ctx.home), "token")
    File.write!(path, token <> "\n")
    File.chmod!(path, 0o600)
    path
  end

  defp mint, do: elem(Nodes.mint_join_token([], @operator), 1).token

  defp run_script(ctx, env \\ []) do
    base = [
      {"PATH", ctx.bin <> ":/usr/bin:/bin"},
      {"HOME", ctx.home},
      {"XDG_RUNTIME_DIR", ctx.run},
      {"TMPDIR", ctx.run},
      {"STUB_LOG", ctx.log},
      {"REAL_STAT", System.find_executable("stat")},
      {"REAL_CURL", System.find_executable("curl")},
      {"ARB_JOIN_FS_ROOT", ctx.fsroot},
      # nothing from the worker's own environment leaks into the scenario
      {"ARB_JOIN_TOKEN", nil},
      {"ARB_JOIN_TOKEN_FILE", nil},
      {"ARB_JOIN_MODE", nil},
      {"ARB_JOIN_CHECK_ONLY", nil},
      {"ARB_NODE_NAME", nil},
      {"ARB_NODE_LABELS", nil},
      {"ARB_NODE_MAX_WORKERS", nil}
    ]

    # setsid: no controlling terminal, so the script can never block on /dev/tty.
    {out, status} =
      System.cmd("setsid", ["--wait", "bash", ctx.script],
        env: base ++ env,
        stderr_to_stdout: true
      )

    {out, status}
  end

  defp log(ctx), do: File.read!(ctx.log)

  defp pending_tokens do
    Arbiter.Nodes.JoinToken |> Ash.read!() |> Enum.filter(&is_nil(&1.used_at))
  end

  describe "ARB_JOIN_CHECK_ONLY=1" do
    test "runs every prerequisite check and exits 0 without reading or spending a token", ctx do
      token = mint()

      {out, 0} =
        run_script(ctx, [
          {"ARB_JOIN_CHECK_ONLY", "1"},
          {"ARB_JOIN_TOKEN_FILE", token_file(ctx, token)}
        ])

      assert out =~ "All prerequisite checks passed"
      assert out =~ "No token was read"

      for check <- ["Linux", "glibc", "podman", "cgroup v2", "memory controller", "linger"] do
        assert out =~ check, "check output is missing #{check}"
      end

      assert length(pending_tokens()) == 1
      assert Nodes.events(kind: :enrolled) == []
      refute log(ctx) =~ "nodes/enroll"
      refute File.exists?(Path.join(ctx.home, ".arbiter-node"))
      refute log(ctx) =~ "enable-linger", "check-only must not change the machine"
    end

    test "a failing check exits non-zero, listing every problem with its remedy", ctx do
      {out, status} =
        run_script(ctx, [
          {"ARB_JOIN_CHECK_ONLY", "1"},
          {"FAKE_ARCH", "aarch64"},
          {"FAKE_PODMAN", "3.4.4"},
          {"FAKE_GLIBC", "2.17"}
        ])

      assert status == 1
      assert out =~ "aarch64"
      assert out =~ "podman 3.4.4 is older"
      assert out =~ "glibc 2.17 is older"
      assert out =~ "Fix these yourself"
    end
  end

  describe "a failing prerequisite" do
    test "refuses before the token is read or spent, however many checks fail", ctx do
      token = mint()

      {out, status} =
        run_script(ctx, [
          {"ARB_JOIN_TOKEN_FILE", token_file(ctx, token)},
          {"FAKE_ARCH", "aarch64"},
          {"FAKE_DISK_KB", "1000"}
        ])

      assert status == 1
      assert out =~ "no token was used"
      assert length(pending_tokens()) == 1
      assert Nodes.events(kind: :join_failed) == []
      refute log(ctx) =~ "nodes/enroll"
      refute File.exists?(Path.join(ctx.home, ".arbiter-node"))
      # and the same token still works afterwards
      assert {:ok, _} = Nodes.redeem_join_token(token, %{name: "later"})
    end

    test "missing memory delegation is refused with a drop-in remedy (never executed)", ctx do
      File.write!(
        Path.join(
          ctx.fsroot,
          "sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/cgroup.subtree_control"
        ),
        "pids\n"
      )

      {out, status} = run_script(ctx, [{"ARB_JOIN_CHECK_ONLY", "1"}])
      assert status == 1
      assert out =~ "memory cgroup controller is not delegated"
      assert out =~ "Delegate=cpu cpuset io memory pids"
      refute log(ctx) =~ "SUDO WAS EXECUTED"
    end

    test "too few subuids is refused", ctx do
      File.write!(Path.join(ctx.fsroot, "etc/subuid"), "tester:100000:1000\n")
      {out, status} = run_script(ctx, [{"ARB_JOIN_CHECK_ONLY", "1"}])
      assert status == 1
      assert out =~ "/etc/subuid grants 1000 ids"
    end
  end

  describe "root" do
    test "is refused outright, before any check", ctx do
      {out, status} = run_script(ctx, [{"FAKE_UID", "0"}])
      assert status == 1
      assert out =~ "refusing to run as root"
      refute out =~ "Checking prerequisites"
      refute log(ctx) =~ "podman"
    end
  end

  describe "sudo" do
    test "is never executed: not on a clean run, not when the linger fix is denied", ctx do
      token = mint()
      tf = token_file(ctx, token)

      {_out, 0} = run_script(ctx, [{"ARB_JOIN_TOKEN_FILE", tf}])
      refute log(ctx) =~ "SUDO WAS EXECUTED"

      File.write!(ctx.log, "")

      {out, status} =
        run_script(ctx, [
          {"ARB_JOIN_TOKEN_FILE", token_file(ctx, mint())},
          {"FAKE_LINGER", "no"},
          {"FAKE_LINGER_FIX_RC", "1"}
        ])

      assert status == 1
      assert out =~ "sudo loginctl enable-linger tester"
      refute log(ctx) =~ "SUDO WAS EXECUTED"
      refute log(ctx) =~ ~r/^sudo /m
    end
  end

  describe "linger" do
    test "the one fix it makes itself: enable-linger for the current user, no sudo", ctx do
      {_out, 0} =
        run_script(ctx, [
          {"ARB_JOIN_TOKEN_FILE", token_file(ctx, mint())},
          {"FAKE_LINGER", "no"}
        ])

      assert log(ctx) =~ "loginctl --no-ask-password enable-linger tester\n"
      refute log(ctx) =~ "SUDO"
    end
  end

  describe "the token" do
    test "in token mode, without a file, env var or terminal the script refuses, and spends nothing",
         ctx do
      mint()
      {out, status} = run_script(ctx, [{"ARB_JOIN_MODE", "token"}])
      assert status == 1
      assert out =~ "no terminal to read the join token from"
      assert out =~ "ARB_JOIN_TOKEN_FILE"
      assert length(pending_tokens()) == 1
      refute log(ctx) =~ "nodes/enroll"
    end

    test "a token file that others can read is refused", ctx do
      path = token_file(ctx, mint())
      File.chmod!(path, 0o644)
      {out, status} = run_script(ctx, [{"ARB_JOIN_TOKEN_FILE", path}])
      assert status == 1
      assert out =~ "must be mode 0600"
      assert length(pending_tokens()) == 1
    end

    test "something that is not a join token is refused locally, never sent", ctx do
      path = token_file(ctx, "not-a-token")
      {out, status} = run_script(ctx, [{"ARB_JOIN_TOKEN_FILE", path}])
      assert status == 1
      assert out =~ "not a join token"
      refute out =~ "not-a-token"
      refute log(ctx) =~ "nodes/enroll"
      assert Nodes.events(kind: :join_failed) == []
    end

    test "from ARB_JOIN_TOKEN works and no child process ever inherits it", ctx do
      token = mint()
      {out, 0} = run_script(ctx, [{"ARB_JOIN_TOKEN", token}])
      assert out =~ "Done."
      refute log(ctx) =~ "LEAK"
      refute log(ctx) =~ token
    end

    test "neither the join token nor the credential is ever on an argv", ctx do
      token = mint()
      {out, 0} = run_script(ctx, [{"ARB_JOIN_TOKEN_FILE", token_file(ctx, token)}])

      credential =
        File.read!(Path.join(ctx.home, ".config/arbiter-node/credential")) |> String.trim()

      assert credential =~ "arbn_"

      stub_log = log(ctx)
      refute stub_log =~ token
      refute stub_log =~ credential
      refute stub_log =~ "arbj_"
      refute stub_log =~ "arbn_"
      # the enroll call is there, with no secret in it
      assert stub_log =~ ~r{curl .*-X POST --data-binary @- .*/nodes/enroll}
      assert stub_log =~ "-K -"
      refute out =~ token
      refute out =~ credential
    end
  end

  describe "pairing (no token supplied)" do
    # The node script runs in a task; this plays the operator on the primary.
    defp approve_when_pending(attrs) do
      Enum.find_value(1..100, fn _ ->
        case Arbiter.Nodes.Pairing.list_pending() do
          [req | _] ->
            {:ok, _} = Arbiter.Nodes.Pairing.approve(req.id, attrs, @operator)
            req

          [] ->
            Process.sleep(100)
            nil
        end
      end)
    end

    test "shows a short code, installs after the operator approves it, and types nothing", ctx do
      task = Task.async(fn -> run_script(ctx, [{"ARB_NODE_NAME", "paired-box"}]) end)
      req = approve_when_pending(%{})
      assert req, "the script never opened a pairing request"
      {out, 0} = Task.await(task, 60_000)

      shown = Arbiter.Nodes.Credentials.format_pairing_code(req.code)
      assert out =~ "Pairing code:   #{shown}"
      assert out =~ "arb node approve #{shown}"
      assert out =~ "Done."

      assert [node] = Nodes.list_nodes()
      assert node.name == "paired-box"
      assert [_] = Nodes.events(kind: :pairing_approved)
      assert [_] = Nodes.events(kind: :enrolled)

      credential =
        File.read!(Path.join(ctx.home, ".config/arbiter-node/credential")) |> String.trim()

      assert credential =~ "arbn_"
      stub_log = log(ctx)
      refute stub_log =~ "arbp_"
      refute stub_log =~ credential
      refute out =~ "arbp_"
      refute out =~ credential
      assert stub_log =~ ~r{curl .*-X POST --data-binary @- .*/nodes/pair/poll}
    end

    test "a denied request installs nothing and exits non-zero", ctx do
      task = Task.async(fn -> run_script(ctx) end)

      req =
        Enum.find_value(1..100, fn _ ->
          case Arbiter.Nodes.Pairing.list_pending() do
            [req | _] -> req
            [] -> Process.sleep(100) && nil
          end
        end)

      {:ok, _} = Arbiter.Nodes.Pairing.deny(req.id, @operator)
      {out, status} = Task.await(task, 60_000)

      assert status == 1
      assert out =~ "denied"
      assert Nodes.list_nodes() == []
      refute File.exists?(Path.join(ctx.home, ".arbiter-node"))
    end

    test "ARB_JOIN_CHECK_ONLY opens no pairing request", ctx do
      {out, 0} = run_script(ctx, [{"ARB_JOIN_CHECK_ONLY", "1"}])
      assert out =~ "no pairing was requested"
      assert Arbiter.Nodes.Pairing.list_pending() == []
    end
  end

  describe "a full install against the real endpoint" do
    test "enrols once, verifies the checksum, unpacks the agent and installs the unit", ctx do
      token = mint()

      {out, 0} =
        run_script(ctx, [
          {"ARB_JOIN_TOKEN_FILE", token_file(ctx, token)},
          {"ARB_NODE_NAME", "box-1"},
          {"ARB_NODE_LABELS", "zone=a,gpu=no"},
          {"ARB_NODE_MAX_WORKERS", "3"}
        ])

      assert out =~ "checksum verified"
      assert out =~ "enrolled as box-1"

      root = Path.join(ctx.home, ".arbiter-node")
      tag = ctx.release.tag
      assert File.exists?(Path.join([root, "releases", tag, "bin/arbiter"]))

      assert {:ok, %File.Stat{mode: mode}} =
               File.stat(Path.join([root, "releases", tag, "bin/arbiter"]))

      assert Bitwise.band(mode, 0o111) != 0
      assert File.read_link!(Path.join(root, "current")) == "releases/#{tag}"
      assert File.exists?(Path.join(root, "bin/arbiter-node"))

      cfg = Path.join(ctx.home, ".config/arbiter-node")
      assert mode_of(cfg) == 0o700
      assert mode_of(Path.join(cfg, "credential")) == 0o600
      assert mode_of(Path.join(cfg, "agent.env")) == 0o600

      env = File.read!(Path.join(cfg, "agent.env"))
      assert env =~ ~s(ARB_ROLE="agent")
      assert env =~ ~s(ARB_NODE_URL="#{ctx.url}")
      assert env =~ ~s(ARB_NODE_CREDENTIAL_FILE="#{cfg}/credential")

      unit = File.read!(Path.join(ctx.home, ".config/systemd/user/arbiter-node.service"))
      assert unit =~ "Environment=ARB_ROLE=agent"
      assert unit =~ "ExecStart=%h/.arbiter-node/current/bin/arbiter start"
      assert unit =~ "Restart=always"

      assert log(ctx) =~ "systemctl --user enable arbiter-node.service"
      assert log(ctx) =~ "systemctl --user restart arbiter-node.service"

      # server side: one node, the credential works, the token is spent, events written
      credential = cfg |> Path.join("credential") |> File.read!() |> String.trim()
      assert {:ok, node} = Nodes.authenticate(credential)
      assert node.name == "box-1"
      assert node.labels == ["zone=a", "gpu=no"]
      assert node.max_workers == 3
      assert pending_tokens() == []
      assert [_] = Nodes.events(kind: :enrolled)
      assert {:error, :invalid_token} = Nodes.redeem_join_token(token, %{})

      # the downloaded bytes are the ones the enroll response described
      assert File.read!(Path.join([root, "releases", tag, ".agent-sha256"])) |> String.trim() ==
               ctx.release.sha256
    end

    test "works when piped from curl exactly like the one-liner", ctx do
      token = mint()
      tf = token_file(ctx, token)

      {out, 0} =
        System.cmd(
          "setsid",
          ["--wait", "bash", "-c", Arbiter.Nodes.JoinScript.one_liner(ctx.url)],
          env: [
            {"PATH", ctx.bin <> ":/usr/bin:/bin"},
            {"HOME", ctx.home},
            {"XDG_RUNTIME_DIR", ctx.run},
            {"TMPDIR", ctx.run},
            {"STUB_LOG", ctx.log},
            {"REAL_STAT", System.find_executable("stat")},
            {"REAL_CURL", System.find_executable("curl")},
            {"ARB_JOIN_FS_ROOT", ctx.fsroot},
            {"ARB_JOIN_TOKEN_FILE", tf}
          ],
          stderr_to_stdout: true
        )

      assert out =~ "Done."
      assert File.exists?(Path.join(ctx.home, ".arbiter-node/current/bin/arbiter"))
    end

    test "the printed one-liner selects token mode: it asks for the token, not a pairing", ctx do
      mint()

      {out, status} =
        System.cmd(
          "setsid",
          ["--wait", "bash", "-c", Arbiter.Nodes.JoinScript.one_liner(ctx.url)],
          env: [
            {"PATH", ctx.bin <> ":/usr/bin:/bin"},
            {"HOME", ctx.home},
            {"XDG_RUNTIME_DIR", ctx.run},
            {"TMPDIR", ctx.run},
            {"STUB_LOG", ctx.log},
            {"REAL_STAT", System.find_executable("stat")},
            {"REAL_CURL", System.find_executable("curl")},
            {"ARB_JOIN_FS_ROOT", ctx.fsroot}
          ],
          stderr_to_stdout: true
        )

      # no terminal under setsid, so token mode refuses; pairing mode would
      # have opened a request instead
      assert status == 1
      assert out =~ "no terminal to read the join token from"
      refute log(ctx) =~ "nodes/pair"
      assert length(pending_tokens()) == 1
    end

    test "is idempotent: a re-run with a new token enrols again and repairs", ctx do
      {_, 0} = run_script(ctx, [{"ARB_JOIN_TOKEN_FILE", token_file(ctx, mint())}])
      File.rm!(Path.join(ctx.home, ".config/systemd/user/arbiter-node.service"))
      File.rm!(Path.join(ctx.home, ".config/arbiter-node/credential"))

      {out, 0} = run_script(ctx, [{"ARB_JOIN_TOKEN_FILE", token_file(ctx, mint())}])

      assert out =~ "is already unpacked"
      assert File.exists?(Path.join(ctx.home, ".config/systemd/user/arbiter-node.service"))
      assert File.exists?(Path.join(ctx.home, ".config/arbiter-node/credential"))
      assert length(Nodes.list_nodes()) == 2
    end

    test "a name that is already taken is refused without spending the token", ctx do
      {_, 0} =
        run_script(ctx, [
          {"ARB_JOIN_TOKEN_FILE", token_file(ctx, mint())},
          {"ARB_NODE_NAME", "dup"}
        ])

      {out, status} =
        run_script(ctx, [
          {"ARB_JOIN_TOKEN_FILE", token_file(ctx, mint())},
          {"ARB_NODE_NAME", "dup"}
        ])

      assert status == 1
      assert out =~ "already exists"
      assert length(pending_tokens()) == 1
    end

    test "a bad token installs nothing", ctx do
      bad = "arbj_" <> String.duplicate("a", 52)
      {out, status} = run_script(ctx, [{"ARB_JOIN_TOKEN_FILE", token_file(ctx, bad)}])
      assert status == 1
      assert out =~ "refused the join token"
      refute File.exists?(Path.join(ctx.home, ".arbiter-node"))
      refute File.exists?(Path.join(ctx.home, ".config/arbiter-node"))
    end

    test "a download that does not match the checksum installs nothing", ctx do
      {out, status} =
        run_script(ctx, [
          {"ARB_JOIN_TOKEN_FILE", token_file(ctx, mint())},
          {"FAKE_CORRUPT", "1"}
        ])

      assert status == 1
      assert out =~ "does not match its checksum"
      refute File.exists?(Path.join(ctx.home, ".arbiter-node/current"))
      refute File.exists?(Path.join(ctx.home, ".arbiter-node/releases/#{ctx.release.tag}"))
    end

    test "unpacks a flat tarball (a hand-rolled --local build) as well as a rooted one", ctx do
      File.rm_rf!(Path.join(ctx.release.home, "current"))
      File.rm_rf!(Path.join(ctx.release.home, "releases"))
      install_release!(ctx.release.home, "local-1", layout: :flat)

      {out, 0} = run_script(ctx, [{"ARB_JOIN_TOKEN_FILE", token_file(ctx, mint())}])

      assert out =~ "Done."
      assert File.exists?(Path.join(ctx.home, ".arbiter-node/releases/local-1/bin/arbiter"))
      assert File.exists?(Path.join(ctx.home, ".arbiter-node/releases/local-1/.agent-sha256"))
      refute File.exists?(Path.join(ctx.home, ".arbiter-node/releases/.stage.1"))
      assert Path.wildcard(Path.join(ctx.home, ".arbiter-node/releases/.stage.*")) == []
    end

    test "leaves no temporary directory behind", ctx do
      {_, 0} = run_script(ctx, [{"ARB_JOIN_TOKEN_FILE", token_file(ctx, mint())}])
      assert Path.wildcard(Path.join(ctx.run, "arbiter-join.*")) == []
    end
  end

  defp mode_of(path) do
    {:ok, %File.Stat{mode: mode}} = File.stat(path)
    Bitwise.band(mode, 0o777)
  end
end
