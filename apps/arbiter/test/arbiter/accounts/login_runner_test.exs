defmodule Arbiter.Accounts.LoginRunnerTest do
  @moduledoc """
  bd-c99hys (login relay 3/6): the supervised `LoginRunner`, driven against the
  fake provider CLIs (bd-82yxz2) inside a REAL tmux server — no systemd, no
  network, no real OAuth.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.LoginRecipes
  alias Arbiter.Accounts.LoginRunner
  alias Arbiter.Sessions
  alias Arbiter.Sessions.Naming
  alias Arbiter.Sessions.Session
  alias Arbiter.Test.DirectTmuxRunner
  alias Arbiter.Test.FakeLoginCli
  alias Arbiter.Test.SessionEnv

  @moduletag :tmux
  @moduletag timeout: 60_000
  @secret "SECRET-PASTE-CODE-8675309"

  setup do
    SessionEnv.sandbox("lr")
    start_supervised!(DirectTmuxRunner)

    on_exit(fn -> kill_login_servers() end)
    :ok
  end

  # Belt and braces: an assertion failing mid-flow must not leave a tmux server
  # behind. Exact socket paths only — never a pattern kill.
  defp kill_login_servers do
    with {:ok, dir} <- Naming.socket_dir() do
      for socket <- Path.wildcard(Path.join(dir, "arb-login-*.sock")) do
        System.cmd("tmux", ["-S", socket, "kill-server"], stderr_to_stdout: true)
      end
    end
  end

  # The fake CLI stands in for the real binary in both the pane command and the
  # status command.
  defp recipe(provider) do
    {:ok, base} = LoginRecipes.fetch(provider)
    script = FakeLoginCli.script(provider)
    %{base | command: script, status_command: [script | tl(base.status_command)]}
  end

  defp start(provider, account, mode, extra \\ []) do
    topic = "login-test:#{System.unique_integer([:positive])}"
    :ok = Phoenix.PubSub.subscribe(Arbiter.PubSub, topic)

    opts =
      [
        provider: provider,
        account: account,
        recipe: recipe(provider),
        topic: topic,
        runner: DirectTmuxRunner,
        extra_env: FakeLoginCli.env(mode),
        poll_interval_ms: 40,
        status_interval_ms: 100,
        enter_delay_ms: 0
      ] ++ extra

    {:ok, id} = LoginRunner.start_login(opts)
    %{id: id, topic: topic}
  end

  defp await_status(id, status, timeout \\ 15_000) do
    assert_receive {:login_state, ^id, %{status: ^status} = snap}, timeout
    snap
  end

  defp tmux_has_session?(socket, name) do
    match?(
      {_, 0},
      System.cmd("tmux", ["-S", socket, "has-session", "-t", name], stderr_to_stdout: true)
    )
  end

  defp login_session(account) do
    [session] =
      Sessions.list(include_kinds: [:login]) |> Enum.filter(&(&1.login_account == account))

    session
  end

  describe "completion (bd-djh1yr)" do
    test "a verified login references the dedicated dir and writes a history row" do
      test_pid = self()

      %{id: id} =
        start(:claude, "complete", :success,
          started_by: "operator",
          completion_opts: [
            quota_refresh: fn account_id -> send(test_pid, {:poll, account_id}) end
          ]
        )

      await_status(id, :awaiting_user)
      assert :ok = LoginRunner.relay_paste(id, @secret)
      await_status(id, :succeeded)

      dir = Path.join(Arbiter.Config.Paths.accounts_root(), "claude-complete")
      {:ok, account} = Arbiter.Accounts.get_account("claude:complete")

      assert [credential] =
               Arbiter.Accounts.ProviderCredential
               |> Ash.read!()
               |> Enum.filter(&(&1.provider_account_id == account.id and &1.active))
               |> Ash.load!(:secret)

      assert credential.secret == Path.join(dir, ".credentials.json")
      assert_receive {:poll, account_id}
      assert account_id == account.id

      assert [record] =
               Arbiter.Accounts.LoginRecord
               |> Ash.read!()
               |> Enum.filter(&(&1.account == "complete"))

      assert record.outcome == :succeeded
      assert record.started_by == "operator"
      assert record.login_id == id
      assert record.fingerprint =~ ~r/\A[0-9a-f]{12}\z/
    end

    test "a cancelled login is recorded with no fingerprint" do
      %{id: id} = start(:claude, "cancelrec", :hang, started_by: "operator")
      await_status(id, :awaiting_user)
      assert :ok = LoginRunner.cancel(id)
      await_status(id, :cancelled)

      assert [record] =
               Arbiter.Accounts.LoginRecord
               |> Ash.read!()
               |> Enum.filter(&(&1.account == "cancelrec"))

      assert record.outcome == :cancelled
      assert record.fingerprint == nil
    end
  end

  describe "paste-code flow (claude)" do
    test "reaches :awaiting_user with the URL and needs_paste?, then verifies and succeeds" do
      %{id: id} = start(:claude, "work", :success)

      snap = await_status(id, :awaiting_user)
      assert snap.url == FakeLoginCli.claude_url()
      assert snap.needs_paste? == true
      assert snap.device_code == nil

      assert :ok = LoginRunner.relay_paste(id, @secret)
      await_status(id, :verifying)
      await_status(id, :succeeded)

      # success comes from the status command reading the credential the CLI wrote
      assert File.exists?(
               Path.join([
                 Arbiter.Config.Paths.accounts_root(),
                 "claude-work",
                 ".credentials.json"
               ])
             )
    end

    test "a pasted code is never in any argv — tmux's included" do
      %{id: id} = start(:claude, "argv", :success)
      await_status(id, :awaiting_user)
      assert :ok = LoginRunner.relay_paste(id, @secret)
      await_status(id, :succeeded)

      calls = DirectTmuxRunner.calls()
      assert calls != []

      refute Enum.any?(calls, fn {cmd, args} ->
               Enum.any?([cmd | args], &String.contains?(&1, @secret))
             end)

      # …and it never appears in the process table while the pane runs either
      {ps, _} = System.cmd("ps", ["-eo", "args"])
      refute ps =~ @secret
      # the paste really was delivered (the fake only succeeds after reading a line)
      assert Enum.any?(calls, fn {_, args} -> "load-buffer" in args end)
    end

    test "rejects input that is not a single printable line" do
      %{id: id} = start(:claude, "badinput", :hang)
      await_status(id, :awaiting_user)
      assert {:error, :invalid_input} = LoginRunner.relay_paste(id, "abc\nrm -rf /")
      assert {:error, :invalid_input} = LoginRunner.relay_paste(id, "")
      assert {:error, :invalid_input} = LoginRunner.relay_paste(id, <<27, "[31m">>)
      assert :ok = LoginRunner.cancel(id)
    end

    test "failure: a rejected code ends in :failed" do
      %{id: id} = start(:claude, "bad", :failure)
      await_status(id, :awaiting_user)
      assert :ok = LoginRunner.relay_paste(id, "wrong")
      snap = await_status(id, :failed)
      assert is_binary(snap.reason)
    end

    test "capture goes through a file (capture-pane -p -J redirected), and OSC-8 is stripped" do
      %{id: id} = start(:claude, "capture", :success)
      snap = await_status(id, :awaiting_user)
      refute snap.url =~ "\e"

      assert Enum.any?(DirectTmuxRunner.calls(), fn
               {"sh", ["-c", script, _name, _socket, _target, _file]} ->
                 script =~ "capture-pane -p -J" and script =~ ">"

               _ ->
                 false
             end)

      assert :ok = LoginRunner.cancel(id)
    end
  end

  describe "device-code flow (codex)" do
    test "exposes URL + code (no paste) and succeeds via the status command" do
      %{id: id} =
        start(:codex, "dev", :success,
          extra_env: FakeLoginCli.env(:success) ++ [{"FAKE_LOGIN_DELAY", "0.6"}]
        )

      snap = await_status(id, :awaiting_user)
      assert snap.url == FakeLoginCli.codex_url()
      assert snap.device_code == FakeLoginCli.codex_code()
      assert snap.needs_paste? == false
      assert {:error, :not_awaiting_code} = LoginRunner.relay_paste(id, "nope")

      await_status(id, :verifying)
      await_status(id, :succeeded)

      assert File.exists?(
               Path.join([Arbiter.Config.Paths.accounts_root(), "codex-dev", "auth.json"])
             )
    end

    test "failure: the CLI exiting non-zero ends in :failed" do
      %{id: id} = start(:codex, "devfail", :failure)
      await_status(id, :awaiting_user)
      snap = await_status(id, :failed)
      assert is_binary(snap.reason)
    end
  end

  describe "limits" do
    test "one active login per account; a different account is fine; the lock frees on completion" do
      %{id: id} = start(:claude, "lock", :hang)
      await_status(id, :awaiting_user)

      assert {:error, :already_active} =
               LoginRunner.start_login(
                 provider: :claude,
                 account: "lock",
                 recipe: recipe(:claude),
                 runner: DirectTmuxRunner
               )

      other = start(:claude, "lock2", :hang)
      await_status(other.id, :awaiting_user)

      assert :ok = LoginRunner.cancel(id)
      await_status(id, :cancelled)

      # the runner stops after its terminal state, releasing the lock
      %{id: again} = start(:claude, "lock", :hang)
      await_status(again, :awaiting_user)
      assert :ok = LoginRunner.cancel(again)
      assert :ok = LoginRunner.cancel(other.id)
    end

    test "cancel kills the tmux session and ends the row" do
      %{id: id} = start(:claude, "cancel", :hang)
      await_status(id, :awaiting_user)
      session = login_session("claude-cancel")
      name = Naming.tmux_session(session)
      assert tmux_has_session?(session.tmux_socket, name)

      assert :ok = LoginRunner.cancel(id)
      await_status(id, :cancelled)

      refute tmux_has_session?(session.tmux_socket, name)
      assert {:ok, %Session{status: :ended}} = Sessions.get(session.id)
    end

    test "timeout ends in :timed_out and kills the tmux session" do
      %{id: id} = start(:claude, "timeout", :hang, timeout_ms: 400)
      snap = await_status(id, :timed_out)
      assert is_binary(snap.reason)

      session = login_session("claude-timeout")
      refute tmux_has_session?(session.tmux_socket, Naming.tmux_session(session))
      assert {:ok, %Session{status: :ended}} = Sessions.get(session.id)
    end

    test "rejects unsupported / disabled providers and malformed account slugs" do
      assert {:error, :unsupported} = LoginRunner.start_login(provider: :agy, account: "x")
      assert {:error, :disabled} = LoginRunner.start_login(provider: :grok, account: "x")

      assert {:error, :invalid_account} =
               LoginRunner.start_login(provider: :claude, account: "../etc")
    end

    test "the account dir is created 0700" do
      %{id: id} = start(:claude, "perm", :hang)
      await_status(id, :awaiting_user)
      dir = Path.join(Arbiter.Config.Paths.accounts_root(), "claude-perm")
      assert %{mode: mode} = File.stat!(dir)
      assert Bitwise.band(mode, 0o777) == 0o700
      assert :ok = LoginRunner.cancel(id)
    end
  end

  describe "boot sweep" do
    test "kills stale arb-login-* tmux sessions and ends their rows" do
      # a login that was running when the previous node died
      %{id: id} = start(:claude, "stale", :hang)
      await_status(id, :awaiting_user)
      session = login_session("claude-stale")
      name = Naming.tmux_session(session)

      # a stray socket with no row behind it
      {:ok, dir} = Naming.socket_dir()
      stray = Path.join(dir, "arb-login-stray-deadbeef.sock")

      {_, 0} =
        System.cmd(
          "tmux",
          [
            "-f",
            "/dev/null",
            "-S",
            stray,
            "new-session",
            "-d",
            "-s",
            "arb-login-stray-deadbeef",
            "sleep 600"
          ],
          stderr_to_stdout: true
        )

      # the "restart": the runner process is gone, its tmux server is not
      pid =
        GenServer.whereis({:via, Registry, {Arbiter.Accounts.LoginRunner.Registry, {:login, id}}})

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      assert tmux_has_session?(session.tmux_socket, name)

      assert %{killed: killed} =
               LoginRunner.Sweep.sweep_on_boot(primary?: true, runner: DirectTmuxRunner)

      assert killed >= 1

      refute tmux_has_session?(session.tmux_socket, name)
      refute tmux_has_session?(stray, "arb-login-stray-deadbeef")
      assert {:ok, %Session{status: :ended}} = Sessions.get(session.id)
    end

    test "a non-primary instance sweeps nothing" do
      assert %{killed: 0} =
               LoginRunner.Sweep.sweep_on_boot(primary?: false, runner: DirectTmuxRunner)
    end
  end

  describe "privacy" do
    test "state is broadcast only to the requested topic" do
      test_pid = self()

      # a bystander on a different topic, as another operator's LiveView would be
      bystander =
        spawn_link(fn ->
          Phoenix.PubSub.subscribe(Arbiter.PubSub, "login-test:other")
          Phoenix.PubSub.subscribe(Arbiter.PubSub, "sessions:lifecycle")
          send(test_pid, :bystander_ready)

          receive do
            {:login_state, _, _} = leaked -> send(test_pid, {:leaked, leaked})
          end
        end)

      assert_receive :bystander_ready

      %{id: id} = start(:claude, "priv", :hang)
      await_status(id, :awaiting_user)
      assert :ok = LoginRunner.cancel(id)
      await_status(id, :cancelled)

      refute_receive {:leaked, _}, 200
      Process.unlink(bystander)
      Process.exit(bystander, :kill)
    end

    test "format_status redacts the URL, device code and pending input" do
      %{id: id} = start(:codex, "redact", :hang)
      await_status(id, :awaiting_user)

      pid =
        GenServer.whereis({:via, Registry, {Arbiter.Accounts.LoginRunner.Registry, {:login, id}}})

      dump = inspect(:sys.get_status(pid), limit: :infinity)
      refute dump =~ FakeLoginCli.codex_code()
      refute dump =~ "auth.openai.com"
      assert :ok = LoginRunner.cancel(id)
    end
  end
end
