defmodule ArbiterWeb.DashboardUpdateControllerTest do
  @moduledoc """
  The dashboard's "Update to vX.Y.Z" button posts here (bd-6umf7z). Only a
  dashboard login (the operator's own browser session, minted by
  `arb dashboard login`) gets through: a bearer token — coordinator, worker or
  MCP — is not a dashboard session and is redirected to the login page, with
  nothing launched.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Release.UpdateCheck

  setup do
    home = Path.join(System.tmp_dir!(), "arb-duc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    arb = Path.join(home, "arb")
    File.write!(arb, "#!/bin/sh\n")
    File.chmod!(arb, 0o755)

    test_pid = self()

    runner = fn cmd, args, _opts ->
      send(test_pid, {:cmd, cmd, args})

      case {cmd, args} do
        {"systemctl", ["--user", "list-units" | _]} -> {"", 0}
        {"systemd-run", _} -> {"Running as unit: x.service\n", 0}
      end
    end

    previous_dir = Application.fetch_env(:arbiter, :data_dir)
    previous_cfg = Application.fetch_env(:arbiter, :self_deploy)
    Application.put_env(:arbiter, :data_dir, home)
    Application.put_env(:arbiter, :self_deploy, cmd: runner, arb_path: arb)

    on_exit(fn ->
      restore(:data_dir, previous_dir)
      restore(:self_deploy, previous_cfg)
      File.rm_rf(home)
    end)

    {:ok, home: home}
  end

  defp restore(key, {:ok, v}), do: Application.put_env(:arbiter, key, v)
  defp restore(key, :error), do: Application.delete_env(:arbiter, key)

  defp start_checker(latest, running) do
    Req.Test.stub(
      UpdateCheck,
      &Req.Test.json(&1, %{"tag_name" => latest, "html_url" => "https://x.test"})
    )

    pid =
      start_supervised!(
        {UpdateCheck,
         enabled: true,
         repo: "acme/arbiter",
         running_version: running,
         initial_delay_ms: :infinity,
         req_options: [plug: {Req.Test, UpdateCheck}]}
      )

    Req.Test.allow(UpdateCheck, self(), pid)
    UpdateCheck.check_now()
  end

  defp session_only, do: dashboard_login(build_conn())

  test "a dashboard session starts the deploy of the latest release and is sent back with a notice" do
    start_checker("v99.0.0", "0.2.0")

    conn = post(session_only(), "/release/deploy", %{})

    assert redirected_to(conn) == "/about"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "v99.0.0"
    assert_received {:cmd, "systemd-run", args}
    assert "--unit=arbiter-deploy-v99.0.0" in args
  end

  test "only the offered release can be deployed from the button" do
    start_checker("v99.0.0", "0.2.0")

    # A forged version in the form is ignored: the button deploys what the
    # update check offered, never a client-chosen tag.
    conn = post(session_only(), "/release/deploy", %{"version" => "v1.0.0"})

    assert redirected_to(conn) == "/about"
    assert_received {:cmd, "systemd-run", args}
    assert "--unit=arbiter-deploy-v99.0.0" in args
    refute "--unit=arbiter-deploy-v1.0.0" in args
  end

  test "with no update available it launches nothing and says so" do
    start_checker("v0.2.0", "0.2.0")

    conn = post(session_only(), "/release/deploy", %{})

    assert redirected_to(conn) == "/about"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no update"
    refute_received {:cmd, "systemd-run", _}
  end

  test "a deploy already running is refused with a notice", %{home: home} do
    start_checker("v99.0.0", "0.2.0")

    File.write!(
      Path.join(home, "deploy-status.json"),
      Jason.encode!(%{
        "state" => "running",
        "tag" => "v98.0.0",
        "pid" => System.pid(),
        "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
    )

    conn = post(session_only(), "/release/deploy", %{})

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "already"
    refute_received {:cmd, "systemd-run", _}
  end

  test "a bearer token without a dashboard session is sent to the login page and launches nothing" do
    start_checker("v99.0.0", "0.2.0")

    for token <- [
          Scope.mint_coordinator(nil, operator: true),
          Scope.mint_coordinator(nil),
          Scope.mint_worker(%{id: "bd-1", workspace_id: "ws-1"})
        ] do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> post("/release/deploy", %{})

      assert redirected_to(conn) == "/login"
    end

    assert redirected_to(post(build_conn(), "/release/deploy", %{})) == "/login"
    refute_received {:cmd, _, _}
  end
end
