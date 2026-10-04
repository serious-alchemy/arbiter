defmodule ArbiterWeb.ProvidersLoginTest do
  @moduledoc """
  Login relay 6/6 (bd-bh50vs): the `/providers` "Log in / Re-authenticate"
  flow, driven against the fake provider CLIs (bd-82yxz2) inside a REAL tmux
  server — no systemd, no network, no real OAuth.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Accounts.LoginRecord
  alias Arbiter.Accounts.LoginRecipes
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Sessions.Naming
  alias Arbiter.Test.DirectTmuxRunner
  alias Arbiter.Test.FakeLoginCli
  alias Arbiter.Test.SessionEnv

  @moduletag :tmux
  @moduletag timeout: 60_000
  @async_timeout 5_000
  @secret "PASTED-CODE-8675309"

  setup do
    SessionEnv.sandbox("plg")
    start_supervised!(DirectTmuxRunner)

    on_exit(fn ->
      with {:ok, dir} <- Naming.socket_dir() do
        for socket <- Path.wildcard(Path.join(dir, "arb-login-*.sock")) do
          System.cmd("tmux", ["-S", socket, "kill-server"], stderr_to_stdout: true)
        end
      end
    end)

    :ok
  end

  # The fake CLI stands in for the real binary in both the pane command and
  # the status command.
  defp fake_opts(mode, extra \\ []) do
    fn provider ->
      {:ok, base} = LoginRecipes.fetch(provider)
      script = FakeLoginCli.script(provider)

      [
        recipe: %{base | command: script, status_command: [script | tl(base.status_command)]},
        runner: DirectTmuxRunner,
        extra_env: FakeLoginCli.env(mode),
        poll_interval_ms: 40,
        status_interval_ms: 100,
        enter_delay_ms: 0,
        completion_opts: [quota_refresh: fn _ -> :ok end]
      ] ++ extra
    end
  end

  defp seam!(opts) do
    previous = Application.fetch_env(:arbiter, :login_start_opts)
    Application.put_env(:arbiter, :login_start_opts, opts)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbiter, :login_start_opts, value)
        :error -> Application.delete_env(:arbiter, :login_start_opts)
      end
    end)
  end

  defp account!(provider, slug),
    do: Ash.create!(ProviderAccount, %{provider: provider, slug: slug})

  defp live_providers(conn) do
    {:ok, view, _html} = live(conn, ~p"/providers")
    {:ok, view, render_async(view, @async_timeout)}
  end

  defp wait_for(view, selector, tries \\ 150) do
    cond do
      has_element?(view, selector) -> :ok
      tries == 0 -> flunk("never saw #{selector}:\n#{render(view)}")
      true -> wait_step(view, selector, tries)
    end
  end

  # No sleeping: block on the next message the view's PubSub subscription
  # delivers to it by pinging the process until it has handled them.
  # A finished login makes the page re-read its rows in `start_async/3`; let
  # that land before the test ends so teardown never kills it mid-query.
  defp wait_terminal(view, account, status) do
    wait_for(view, ~s{#login-panel-#{account.id}[data-status="#{status}"]})
    render_async(view, @async_timeout)
  end

  defp wait_step(view, selector, tries) do
    _ = :sys.get_state(view.pid)
    Process.send_after(self(), :tick, 20)
    receive do: (:tick -> :ok)
    wait_for(view, selector, tries - 1)
  end

  defp off_box(conn) do
    conn
    |> Map.put(:remote_ip, {10, 0, 0, 7})
    |> put_private(:live_view_connect_info, %{
      peer_data: %{address: {10, 0, 0, 7}, port: 1, ssl_cert: nil}
    })
  end

  describe "paste-code flow (claude)" do
    test "start → sign-in button + paste box → submit → success, then history", %{conn: conn} do
      seam!(fake_opts(:success))
      account = account!(:claude, "lg-paste")
      {:ok, view, _} = live_providers(conn)

      assert has_element?(view, "#login-start-#{account.id}", "Log in")

      view |> element("#login-start-#{account.id}") |> render_click()
      wait_for(view, "#login-open-#{account.id}")

      assert has_element?(
               view,
               ~s{#login-open-#{account.id}[target="_blank"][href="#{FakeLoginCli.claude_url()}"]}
             )

      assert has_element?(view, "#login-paste-form-#{account.id}")
      refute has_element?(view, "#login-device-code-#{account.id}")
      # one login at a time per account
      assert has_element?(view, "#login-start-#{account.id}[disabled]")

      view
      |> form("#login-paste-form-#{account.id}", %{"login" => %{"code" => @secret}})
      |> render_submit()

      wait_terminal(view, account, "succeeded")
      refute has_element?(view, "#login-paste-form-#{account.id}")
      refute render(view) =~ @secret

      # a finished login re-reads the page: the history row and the new button
      wait_for(view, "#login-history-#{account.id} li")
      assert has_element?(view, "#login-start-#{account.id}", "Re-authenticate")
      refute has_element?(view, "#login-start-#{account.id}[disabled]")
      assert has_element?(view, "#login-history-#{account.id} li", "succeeded")
      assert has_element?(view, ~s{#login-history-#{account.id} a[href*="/transcript"]})
    end

    test "a rejected code ends in a failure state", %{conn: conn} do
      seam!(fake_opts(:failure))
      account = account!(:claude, "lg-fail")
      {:ok, view, _} = live_providers(conn)

      view |> element("#login-start-#{account.id}") |> render_click()
      wait_for(view, "#login-paste-form-#{account.id}")

      view
      |> form("#login-paste-form-#{account.id}", %{"login" => %{"code" => "nope"}})
      |> render_submit()

      wait_terminal(view, account, "failed")
    end

    test "Cancel ends the login and frees the account", %{conn: conn} do
      seam!(fake_opts(:hang))
      account = account!(:claude, "lg-cancel")
      {:ok, view, _} = live_providers(conn)

      view |> element("#login-start-#{account.id}") |> render_click()
      wait_for(view, "#login-open-#{account.id}")

      view |> element("#login-cancel-#{account.id}") |> render_click()
      wait_terminal(view, account, "cancelled")
      refute has_element?(view, "#login-start-#{account.id}[disabled]")
    end

    test "a login that outlives its timeout shows timed out", %{conn: conn} do
      seam!(fake_opts(:hang, timeout_ms: 600))
      account = account!(:claude, "lg-timeout")
      {:ok, view, _} = live_providers(conn)

      view |> element("#login-start-#{account.id}") |> render_click()
      wait_terminal(view, account, "timed_out")
    end

    test "the terminal fallback is in a collapsed section", %{conn: conn} do
      seam!(fake_opts(:hang))
      account = account!(:claude, "lg-term")
      {:ok, view, _} = live_providers(conn)

      view |> element("#login-start-#{account.id}") |> render_click()
      wait_for(view, "#login-terminal-#{account.id}")
      assert has_element?(view, ~s{#login-terminal-#{account.id}[data-open="false"]})
      refute has_element?(view, "#login-terminal-#{account.id} [data-arb-terminal]")

      view |> element("#login-terminal-toggle-#{account.id}") |> render_click()
      assert has_element?(view, ~s{#login-terminal-#{account.id}[data-open="true"]})
      assert has_element?(view, "#login-terminal-#{account.id} [data-arb-terminal]")
      view |> element("#login-cancel-#{account.id}") |> render_click()
      wait_terminal(view, account, "cancelled")
    end
  end

  describe "phone width" do
    # No browser here, so this asserts the layout contract in the markup: the
    # panel stacks (flex-col → sm:flex-row), the primary action is a 44px tap
    # target and the device code wraps instead of overflowing.
    test "the panel stacks, taps are large and codes wrap", %{conn: conn} do
      seam!(fake_opts(:hang))
      claude = account!(:claude, "lg-phone")
      codex = account!(:codex, "lg-phone-dev")
      {:ok, view, _} = live_providers(conn)

      view |> element("#login-start-#{claude.id}") |> render_click()
      view |> element("#login-start-#{codex.id}") |> render_click()
      wait_for(view, "#login-paste-form-#{claude.id}")
      wait_for(view, "#login-device-code-#{codex.id}")

      assert has_element?(view, "#login-open-#{claude.id}.h-11")
      assert has_element?(view, "#login-paste-form-#{claude.id}.flex-col.sm\\:flex-row")
      assert has_element?(view, "#login-device-code-#{codex.id}.break-all")

      for account <- [claude, codex] do
        view |> element("#login-cancel-#{account.id}") |> render_click()
        wait_terminal(view, account, "cancelled")
      end
    end
  end

  describe "device-code flow (codex)" do
    test "shows the device code and sign-in button, no paste box, then succeeds", %{conn: conn} do
      seam!(fake_opts(:success, []))
      account = account!(:codex, "lg-dev")
      {:ok, view, _} = live_providers(conn)

      view |> element("#login-start-#{account.id}") |> render_click()
      wait_for(view, "#login-device-code-#{account.id}")

      assert has_element?(view, "#login-device-code-#{account.id}", FakeLoginCli.codex_code())
      assert has_element?(view, "#login-open-#{account.id}")
      refute has_element?(view, "#login-paste-form-#{account.id}")

      wait_terminal(view, account, "succeeded")
    end
  end

  describe "operator gate" do
    test "a non-loopback session sees no action and cannot start one", %{conn: conn} do
      seam!(fake_opts(:hang))
      account = account!(:claude, "lg-gate")
      {:ok, view, _} = live_providers(off_box(conn))

      refute has_element?(view, "#login-start-#{account.id}")

      render_click(view, "start_login", %{"id" => account.id})
      refute has_element?(view, "#login-panel-#{account.id}")
      assert Ash.read!(LoginRecord) == []
    end
  end

  test "history lists past logins with a transcript link", %{conn: conn} do
    account = account!(:claude, "lg-hist")
    now = DateTime.utc_now()

    record =
      Ash.create!(LoginRecord, %{
        login_id: Ash.UUID.generate(),
        provider: :claude,
        account: "lg-hist",
        provider_account_id: account.id,
        started_by: "operator",
        started_at: DateTime.add(now, -30),
        ended_at: now,
        outcome: :succeeded,
        fingerprint: "0123456789ab",
        transcript: "Opened https://claude.com/x?[REDACTED]"
      })

    {:ok, view, _} = live_providers(conn)
    assert has_element?(view, "#login-history-#{account.id} li", "0123456789ab")
    assert has_element?(view, "#login-history-#{account.id} li", "operator")

    transcript = get(conn, ~p"/providers/logins/#{record.id}/transcript")
    assert text_response(transcript, 200) =~ "[REDACTED]"
    assert get(off_box(conn), ~p"/providers/logins/#{record.id}/transcript").status == 403
    assert get(conn, ~p"/providers/logins/#{Ash.UUID.generate()}/transcript").status == 404
  end
end
