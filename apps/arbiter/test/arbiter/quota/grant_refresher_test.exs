defmodule Arbiter.Quota.GrantRefresherTest do
  @moduledoc """
  `Arbiter.Quota.GrantRefresher` (bd-b632tz) keeps the quota poller's
  dedicated Claude grant alive by letting the `claude` CLI refresh it —
  driven here against a fake CLI that records how it was invoked and
  rewrites the grant the way a real refresh does.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.Quota.GrantRefresher
  alias Arbiter.Tasks.Workspace

  @moduletag :tmp_dir

  @hour_ms 3_600_000

  setup %{tmp_dir: tmp_dir} do
    # The fake CLI's cwd must be neutral; the ExUnit tmp_dir sits inside
    # this repo's worktree, so the neutral dir lives under the system tmp dir.
    cwd =
      Path.join(System.tmp_dir!(), "grant-refresher-cwd-#{System.unique_integer([:positive])}")

    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf(cwd) end)

    config_dir = Path.join(tmp_dir, "quota-claude")
    File.mkdir_p!(config_dir)
    grant = Path.join(config_dir, ".credentials.json")
    record = Path.join(tmp_dir, "cli-record")

    ws = Ash.create!(Workspace, %{name: "grant-refresher-ws"})

    %{cwd: cwd, config_dir: config_dir, grant: grant, record: record, tmp_dir: tmp_dir, ws: ws}
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp write_grant!(path, expires_at_ms, refresh_expires_at_ms \\ nil) do
    oauth =
      %{"accessToken" => "access", "refreshToken" => "refresh", "expiresAt" => expires_at_ms}
      |> then(fn o ->
        if refresh_expires_at_ms,
          do: Map.put(o, "refreshTokenExpiresAt", refresh_expires_at_ms),
          else: o
      end)

    File.write!(path, Jason.encode!(%{"claudeAiOauth" => oauth}))
  end

  # A stand-in for `claude`: appends how it was run to `record`, then either
  # renews the grant in `$CLAUDE_CONFIG_DIR` (as a real refresh does) or
  # exits non-zero without touching it.
  defp fake_cli!(%{tmp_dir: tmp_dir, record: record}, mode) do
    path = Path.join(tmp_dir, "fake-claude")

    renew =
      case mode do
        :renews ->
          ~s(printf '{"claudeAiOauth":{"accessToken":"renewed","refreshToken":"r2","expiresAt":%s}}' ) <>
            ~s("#{now_ms() + 8 * @hour_ms}" > "$CLAUDE_CONFIG_DIR/.credentials.json"\nexit 0)

        :fails ->
          "echo 'Not logged in' >&2\nexit 1"

        :no_op ->
          "exit 0"
      end

    File.write!(path, """
    #!/bin/sh
    {
      echo "cwd=$(pwd)"
      echo "config_dir=$CLAUDE_CONFIG_DIR"
      echo "oauth_env=${CLAUDE_CODE_OAUTH_TOKEN-unset}"
      echo "args=$*"
    } >> "#{record}"
    #{renew}
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp start_refresher(ctx, cli, opts \\ []) do
    grant = ctx.grant

    start_supervised!(
      {GrantRefresher,
       Keyword.merge(
         [
           name: nil,
           enabled: true,
           interval_ms: @hour_ms,
           claude_cmd: cli,
           cwd: ctx.cwd,
           grants_fun: fn -> [%{account_id: "acct", path: grant}] end
         ],
         opts
       )}
    )
  end

  defp record_lines(record) do
    case File.read(record) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp escalations, do: Message.inbox(Message.coordinator_ref())

  test "leaves a grant alone while its access token is far from expiry", ctx do
    write_grant!(ctx.grant, now_ms() + 2 * @hour_ms)
    pid = start_refresher(ctx, fake_cli!(ctx, :renews))

    GrantRefresher.tick(pid)

    assert record_lines(ctx.record) == []
    assert escalations() == []
  end

  test "renews a grant inside the CLI's refresh window by running claude with its CLAUDE_CONFIG_DIR from a neutral cwd",
       ctx do
    write_grant!(ctx.grant, now_ms() + 2 * 60_000)
    before = File.read!(ctx.grant)

    previous = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")
    System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "must-not-reach-the-refresh")

    on_exit(fn ->
      if previous,
        do: System.put_env("CLAUDE_CODE_OAUTH_TOKEN", previous),
        else: System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
    end)

    pid = start_refresher(ctx, fake_cli!(ctx, :renews))
    GrantRefresher.tick(pid)

    lines = record_lines(ctx.record)
    assert "config_dir=#{ctx.config_dir}" in lines
    # The CLI must refresh the grant file, not authenticate off a token in env.
    assert "oauth_env=unset" in lines
    assert Enum.any?(lines, &String.starts_with?(&1, "args=-p "))

    ["cwd=" <> cwd] = Enum.filter(lines, &String.starts_with?(&1, "cwd="))
    assert Path.expand(cwd) == Path.expand(ctx.cwd)
    assert GrantRefresher.neutral_cwd?(cwd)
    refute inside_git_work_tree?(cwd)
    refute cwd == Path.expand("~/dev/admiral")

    refute File.read!(ctx.grant) == before
    assert GrantRefresher.state(pid).grants[ctx.grant].status == :ok
    assert escalations() == []
  end

  test "a failed refresh escalates exactly once, naming the re-login command", ctx do
    write_grant!(ctx.grant, now_ms() + 60_000)
    pid = start_refresher(ctx, fake_cli!(ctx, :fails), failure_backoff_ms: 0)

    ExUnit.CaptureLog.capture_log(fn ->
      for _ <- 1..3, do: GrantRefresher.tick(pid)
    end)

    assert length(record_lines(ctx.record)) == 3 * 4

    [msg] = escalations()
    assert msg.kind == :escalation
    assert msg.subject =~ "quota grant needs re-login"
    assert msg.body =~ "CLAUDE_CONFIG_DIR=#{ctx.config_dir} claude auth login"
    assert GrantRefresher.state(pid).grants[ctx.grant].status == :failing
  end

  test "after a failed refresh the CLI is not re-run until the backoff lapses", ctx do
    write_grant!(ctx.grant, now_ms() + 60_000)
    pid = start_refresher(ctx, fake_cli!(ctx, :fails), failure_backoff_ms: @hour_ms)

    ExUnit.CaptureLog.capture_log(fn ->
      for _ <- 1..3, do: GrantRefresher.tick(pid)
    end)

    assert length(record_lines(ctx.record)) == 4
  end

  test "a failing grant recovers once the operator logs it in again", ctx do
    write_grant!(ctx.grant, now_ms() + 60_000)
    pid = start_refresher(ctx, fake_cli!(ctx, :fails), failure_backoff_ms: 0)

    ExUnit.CaptureLog.capture_log(fn -> GrantRefresher.tick(pid) end)
    assert GrantRefresher.state(pid).grants[ctx.grant].status == :failing

    # `claude auth login` wrote a fresh grant.
    write_grant!(ctx.grant, now_ms() + 8 * @hour_ms)
    GrantRefresher.tick(pid)
    assert GrantRefresher.state(pid).grants[ctx.grant].status == :ok
  end

  test "a CLI that exits 0 without moving expiresAt is a failed refresh", ctx do
    write_grant!(ctx.grant, now_ms() + 60_000)
    pid = start_refresher(ctx, fake_cli!(ctx, :no_op), failure_backoff_ms: 0)

    ExUnit.CaptureLog.capture_log(fn ->
      GrantRefresher.tick(pid)
      GrantRefresher.tick(pid)
    end)

    [msg] = escalations()
    assert msg.body =~ "expiresAt did not move"
  end

  test "an unreadable grant escalates once without running the CLI", ctx do
    pid = start_refresher(ctx, fake_cli!(ctx, :renews))

    ExUnit.CaptureLog.capture_log(fn ->
      GrantRefresher.tick(pid)
      GrantRefresher.tick(pid)
    end)

    assert record_lines(ctx.record) == []
    [msg] = escalations()
    assert msg.subject =~ "quota grant needs re-login"
  end

  test "a refresh token expiring within 7 days escalates exactly once", ctx do
    write_grant!(ctx.grant, now_ms() + 2 * @hour_ms, now_ms() + 3 * 24 * @hour_ms)
    pid = start_refresher(ctx, fake_cli!(ctx, :renews))

    for _ <- 1..3, do: GrantRefresher.tick(pid)

    [msg] = escalations()
    assert msg.subject =~ "quota grant expires soon"
    assert msg.body =~ "CLAUDE_CONFIG_DIR=#{ctx.config_dir} claude auth login"
    # Advance notice only: the access token is fine, so the CLI never ran.
    assert record_lines(ctx.record) == []
  end

  test "a refresh token with more than 7 days left does not escalate", ctx do
    write_grant!(ctx.grant, now_ms() + 2 * @hour_ms, now_ms() + 20 * 24 * @hour_ms)
    pid = start_refresher(ctx, fake_cli!(ctx, :renews))

    GrantRefresher.tick(pid)

    assert escalations() == []
  end

  test "refuses to run the CLI from a cwd inside a repo", ctx do
    write_grant!(ctx.grant, now_ms() + 60_000)
    # The ExUnit tmp_dir is inside this repo's worktree.
    pid = start_refresher(ctx, fake_cli!(ctx, :renews), cwd: ctx.tmp_dir)

    ExUnit.CaptureLog.capture_log(fn -> GrantRefresher.tick(pid) end)

    assert record_lines(ctx.record) == []
    [msg] = escalations()
    assert msg.body =~ "cwd_not_neutral"
  end

  test "neutral_cwd?/1 rejects a repo and a directory carrying agent instructions", ctx do
    refute GrantRefresher.neutral_cwd?(ctx.tmp_dir)

    admiral_like = Path.join(ctx.cwd, "admiral")
    File.mkdir_p!(admiral_like)
    File.write!(Path.join(admiral_like, "CLAUDE.md"), "you are the coordinator")
    refute GrantRefresher.neutral_cwd?(admiral_like)
    refute GrantRefresher.neutral_cwd?(Path.join(admiral_like, "sub"))

    assert GrantRefresher.neutral_cwd?(ctx.cwd)
  end

  defp inside_git_work_tree?(dir) do
    case System.cmd("git", ["-C", dir, "rev-parse", "--is-inside-work-tree"],
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> true
      _ -> false
    end
  end
end
