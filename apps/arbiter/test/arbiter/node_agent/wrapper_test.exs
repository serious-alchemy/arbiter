defmodule Arbiter.NodeAgent.WrapperTest do
  @moduledoc """
  `arbiter-node status | logs | leave` (docs/design/remote-workers.md §5.5), the
  POSIX-sh wrapper shipped in the release at `share/arbiter-node/`. It runs here
  with stub `systemctl` / `journalctl` / `curl` on PATH that record their argv and
  stdin, so the tests can also assert the credential never reaches argv.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../../../../rel/overlays/share/arbiter-node/arbiter-node", __DIR__)
  @unit Path.expand(
          "../../../../../rel/overlays/share/arbiter-node/arbiter-node.service",
          __DIR__
        )
  @credential "arbn_node123." <> String.duplicate("S", 52)

  setup do
    root = Path.join(System.tmp_dir!(), "arb-wrapper-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    node_home = Path.join(home, ".arbiter-node")
    config_dir = Path.join(home, ".config/arbiter-node")
    bin = Path.join(root, "bin")
    log = Path.join(root, "calls.log")
    File.mkdir_p!(node_home)
    File.mkdir_p!(config_dir)
    File.mkdir_p!(bin)
    File.write!(log, "")
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(config_dir, "agent.env"), """
    ARB_ROLE=agent
    ARB_NODE_URL=https://primary.example.ts.net
    """)

    File.write!(Path.join(config_dir, "credential"), @credential <> "\n")
    File.chmod!(Path.join(config_dir, "credential"), 0o600)

    stub(bin, "systemctl", """
    echo "systemctl $*" >> "$STUB_LOG"
    case "$*" in
      *is-active*) [ "${STUB_UNIT_ACTIVE:-1}" = 1 ] && { echo active; exit 0; } || { echo inactive; exit 3; } ;;
    esac
    exit 0
    """)

    stub(bin, "journalctl", ~S|echo "journalctl $*" >> "$STUB_LOG"|)

    stub(bin, "curl", """
    echo "curl $*" >> "$STUB_LOG"
    cat > "$STUB_LOG.curl_stdin"
    exit "${STUB_CURL_EXIT:-0}"
    """)

    env = [
      {"HOME", home},
      {"PATH", bin <> ":/usr/bin:/bin"},
      {"STUB_LOG", log},
      {"XDG_CONFIG_HOME", Path.join(home, ".config")},
      {"ARB_NODE_HOME", ""},
      {"ARB_NODE_URL", ""},
      {"ARB_NODE_CREDENTIAL_FILE", ""}
    ]

    %{root: root, home: home, node_home: node_home, config_dir: config_dir, env: env, log: log}
  end

  defp stub(bin, name, body) do
    path = Path.join(bin, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
  end

  # stdin is /dev/null: a prompt that tried to read a confirmation sees EOF, as
  # it would with no terminal.
  defp run(ctx, args, extra_env \\ []) do
    System.cmd("sh", ["-c", ~S(exec sh "$0" "$@" </dev/null), @script | args],
      env: ctx.env ++ extra_env,
      stderr_to_stdout: true
    )
  end

  defp calls(ctx), do: File.read!(ctx.log)

  defp write_status(ctx, state) do
    File.write!(
      Path.join(ctx.node_home, "status.json"),
      ~s({\n  "state": "#{state}",\n  "agent_version": "1.0.0"\n}\n)
    )
  end

  describe "status" do
    test "ready and the unit active: prints the status and exits 0", ctx do
      write_status(ctx, "ready")
      {out, code} = run(ctx, ["status"])

      assert code == 0
      assert out =~ "unit: active"
      assert out =~ ~s("state": "ready")
      assert calls(ctx) =~ "systemctl --user is-active arbiter-node.service"
    end

    test "connecting is not ready: exit 1, so a join script can poll it", ctx do
      write_status(ctx, "connecting")
      {out, code} = run(ctx, ["status"])
      assert code == 1
      assert out =~ ~s("state": "connecting")
    end

    test "an inactive unit is exit 1 even with a stale ready status file", ctx do
      write_status(ctx, "ready")
      {out, code} = run(ctx, ["status"], [{"STUB_UNIT_ACTIVE", "0"}])
      assert code == 1
      assert out =~ "unit: inactive"
    end

    test "no status file says so and exits 1", ctx do
      {out, code} = run(ctx, ["status"])
      assert code == 1
      assert out =~ "no status file"
    end

    test "never prints the credential", ctx do
      write_status(ctx, "ready")
      {out, _} = run(ctx, ["status"])
      refute out =~ "SSSS"
    end
  end

  describe "logs" do
    test "defaults to the last 200 lines of the user unit", ctx do
      {_out, 0} = run(ctx, ["logs"])
      assert calls(ctx) =~ "journalctl --user -u arbiter-node.service -n 200 --no-pager"
    end

    test "passes journalctl arguments through (e.g. -f)", ctx do
      {_out, 0} = run(ctx, ["logs", "-f"])
      assert calls(ctx) =~ "journalctl --user -u arbiter-node.service -f"
      refute calls(ctx) =~ "--no-pager"
    end
  end

  describe "leave" do
    test "asks the primary to remove the node, then stops and disables the unit and drops the credential",
         ctx do
      {out, code} = run(ctx, ["leave", "--yes"])
      assert code == 0, out

      calls = calls(ctx)
      assert calls =~ "https://primary.example.ts.net/nodes/self"
      assert calls =~ "-X DELETE"
      assert calls =~ "systemctl --user disable --now arbiter-node.service"
      refute File.exists?(Path.join(ctx.config_dir, "credential"))

      # the primary was asked before the unit was touched
      {curl_at, _} = :binary.match(calls, "curl ")
      {disable_at, _} = :binary.match(calls, "systemctl --user disable")
      assert curl_at < disable_at
    end

    test "the credential goes to curl on stdin, never on argv", ctx do
      {_out, 0} = run(ctx, ["leave", "--yes"])

      refute calls(ctx) =~ "arbn_"
      refute calls(ctx) =~ "SSSS"
      stdin = File.read!(ctx.log <> ".curl_stdin")
      assert stdin =~ "Authorization: Bearer #{@credential}"
    end

    test "without --yes and no terminal it refuses and changes nothing", ctx do
      {out, code} = run(ctx, ["leave"])
      assert code != 0
      assert out =~ "--yes"
      assert calls(ctx) == ""
      assert File.exists?(Path.join(ctx.config_dir, "credential"))
    end

    test "when the primary cannot be asked it stops and keeps the credential", ctx do
      {out, code} = run(ctx, ["leave", "--yes"], [{"STUB_CURL_EXIT", "22"}])

      assert code == 1
      assert out =~ "--force"
      refute calls(ctx) =~ "disable"
      assert File.exists?(Path.join(ctx.config_dir, "credential"))
    end

    test "--force leaves anyway when the primary is unreachable", ctx do
      {_out, code} = run(ctx, ["leave", "--yes", "--force"], [{"STUB_CURL_EXIT", "7"}])

      assert code == 0
      assert calls(ctx) =~ "systemctl --user disable --now arbiter-node.service"
      refute File.exists?(Path.join(ctx.config_dir, "credential"))
    end

    test "an environment URL and credential file override agent.env", ctx do
      other = Path.join(ctx.root, "other-credential")
      File.write!(other, "arbn_other." <> String.duplicate("T", 52))

      {_out, 0} =
        run(ctx, ["leave", "--yes"], [
          {"ARB_NODE_URL", "http://127.0.0.1:4848"},
          {"ARB_NODE_CREDENTIAL_FILE", other}
        ])

      assert calls(ctx) =~ "http://127.0.0.1:4848/nodes/self"
      assert File.read!(ctx.log <> ".curl_stdin") =~ "arbn_other."
    end
  end

  describe "pre-start (the unit's ExecStartPre rollback, §6 step 4)" do
    setup ctx do
      for v <- ["1.0.0", "2.0.0"] do
        bin = Path.join(ctx.node_home, "releases/#{v}/bin")
        File.mkdir_p!(bin)
        File.write!(Path.join(bin, "arbiter"), "#!/bin/sh\n")
        File.chmod!(Path.join(bin, "arbiter"), 0o755)
      end

      File.ln_s!("releases/2.0.0", Path.join(ctx.node_home, "current"))
      :ok
    end

    defp pending(ctx, age_s) do
      at = System.os_time(:second) - age_s

      File.write!(
        Path.join(ctx.node_home, "upgrade.pending"),
        "from=releases/1.0.0\nto=2.0.0\nat=#{at}\n"
      )
    end

    test "an upgrade never confirmed after three minutes is rolled back", ctx do
      pending(ctx, 400)
      {out, 0} = run(ctx, ["pre-start"])

      assert out =~ "rolling back"
      assert File.read_link!(Path.join(ctx.node_home, "current")) == "releases/1.0.0"
      refute File.exists?(Path.join(ctx.node_home, "upgrade.pending"))
      assert File.read!(Path.join(ctx.node_home, "rolled_back")) =~ "2.0.0"
    end

    test "a fresh pending upgrade is left to start", ctx do
      pending(ctx, 5)
      {_out, 0} = run(ctx, ["pre-start"])

      assert File.read_link!(Path.join(ctx.node_home, "current")) == "releases/2.0.0"
      assert File.exists?(Path.join(ctx.node_home, "upgrade.pending"))
    end

    test "nothing pending is a no-op", ctx do
      {_out, 0} = run(ctx, ["pre-start"])
      assert File.read_link!(Path.join(ctx.node_home, "current")) == "releases/2.0.0"
    end

    test "a rollback target that no longer exists is not followed", ctx do
      File.rm_rf!(Path.join(ctx.node_home, "releases/1.0.0"))
      pending(ctx, 400)
      {_out, code} = run(ctx, ["pre-start"])

      assert code == 0
      assert File.read_link!(Path.join(ctx.node_home, "current")) == "releases/2.0.0"
    end
  end

  test "an unknown command prints usage and exits 2", ctx do
    {out, code} = run(ctx, ["frobnicate"])
    assert code == 2
    assert out =~ "usage: arbiter-node"
  end

  describe "the systemd unit" do
    test "restarts always and pins the agent role, node home and a node name of its own" do
      unit = File.read!(@unit)

      assert unit =~ "Restart=always"
      assert unit =~ "Environment=ARB_ROLE=agent"
      assert unit =~ "ARB_DATA_HOME=%h/.arbiter-node"
      assert unit =~ "RELEASE_NODE=arbiter_node@127.0.0.1"
      assert unit =~ "ExecStart=%h/.arbiter-node/current/bin/arbiter start"
      assert unit =~ "ExecStartPre=%h/.arbiter-node/bin/arbiter-node pre-start"
      assert unit =~ "EnvironmentFile=%h/.config/arbiter-node/agent.env"
    end
  end
end
