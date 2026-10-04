defmodule ArbiterWeb.Api.AccountLoginControllerTest do
  @moduledoc """
  The REST side of `arb account login` (bd-bh50vs), against the fake provider
  CLIs inside a real tmux server.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Accounts.LoginRecipes
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Sessions.Naming
  alias Arbiter.Test.DirectTmuxRunner
  alias Arbiter.Test.FakeLoginCli
  alias Arbiter.Test.SessionEnv

  @moduletag :tmux
  @moduletag timeout: 60_000
  @secret "API-PASTED-CODE-42"

  setup do
    SessionEnv.sandbox("alc")
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

  defp seam!(mode) do
    previous = Application.fetch_env(:arbiter, :login_start_opts)

    Application.put_env(:arbiter, :login_start_opts, fn provider ->
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
      ]
    end)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbiter, :login_start_opts, value)
        :error -> Application.delete_env(:arbiter, :login_start_opts)
      end
    end)
  end

  defp poll(conn, id, status, tries \\ 200) do
    body = conn |> get(~p"/api/account_logins/#{id}") |> json_response(200)

    cond do
      body["status"] == status -> body
      tries == 0 -> flunk("never reached #{status}: #{inspect(body)}")
      true -> poll_again(conn, id, status, tries)
    end
  end

  defp poll_again(conn, id, status, tries) do
    Process.send_after(self(), :tick, 25)
    receive do: (:tick -> :ok)
    poll(conn, id, status, tries - 1)
  end

  test "start → awaiting_user with the URL → paste in the body → succeeded (and the record answers after the runner is gone)",
       %{conn: conn} do
    seam!(:success)
    Ash.create!(ProviderAccount, %{provider: :claude, slug: "api-paste"})

    started = conn |> post(~p"/api/accounts/claude:api-paste/login") |> json_response(201)
    id = started["id"]

    awaiting = poll(conn, id, "awaiting_user")
    assert awaiting["url"] == FakeLoginCli.claude_url()
    assert awaiting["needs_paste"] == true

    assert %{"id" => ^id} =
             conn
             |> post(~p"/api/account_logins/#{id}/paste", %{code: @secret})
             |> json_response(200)

    assert poll(conn, id, "succeeded")["account"] == "api-paste"

    # the runner is gone; the recorded outcome still answers
    assert conn |> get(~p"/api/account_logins/#{id}") |> json_response(200) |> Map.get("status") ==
             "succeeded"
  end

  test "a second start for the account is a 409, an unknown account a 404, and a cancel ends it",
       %{conn: conn} do
    seam!(:hang)
    Ash.create!(ProviderAccount, %{provider: :claude, slug: "api-dup"})

    id =
      conn |> post(~p"/api/accounts/claude:api-dup/login") |> json_response(201) |> Map.get("id")

    assert conn |> post(~p"/api/accounts/claude:api-dup/login") |> json_response(409)
    assert conn |> post(~p"/api/accounts/claude:nope/login") |> json_response(404)

    poll(conn, id, "awaiting_user")
    assert conn |> post(~p"/api/account_logins/#{id}/cancel") |> json_response(200)
    poll(conn, id, "cancelled")
  end

  test "pasting a bad code or to an unknown login is refused", %{conn: conn} do
    seam!(:hang)
    Ash.create!(ProviderAccount, %{provider: :claude, slug: "api-bad"})

    id =
      conn |> post(~p"/api/accounts/claude:api-bad/login") |> json_response(201) |> Map.get("id")

    poll(conn, id, "awaiting_user")

    assert conn
           |> post(~p"/api/account_logins/#{id}/paste", %{code: "a\nb"})
           |> json_response(400)

    assert conn |> post(~p"/api/account_logins/#{id}/paste", %{}) |> json_response(400)

    assert conn
           |> post(~p"/api/account_logins/#{Ash.UUID.generate()}/paste", %{code: "x"})
           |> json_response(404)

    conn |> post(~p"/api/account_logins/#{id}/cancel")
    poll(conn, id, "cancelled")
  end

  test "workers are refused (coordinator tier only)" do
    conn = Phoenix.ConnTest.build_conn() |> post(~p"/api/accounts/claude:x/login")
    assert conn.status in [401, 403]
  end
end
