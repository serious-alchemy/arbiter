defmodule ArbiterWeb.Api.ReleaseDeployControllerTest do
  @moduledoc """
  `POST /api/release/deploy` (bd-6umf7z): launch `arb server deploy` in its own
  systemd unit. `:operator` in `ArbiterWeb.ApiPolicy` — a coordinator session (an
  LLM), a worker and anonymous callers are refused, and refusing must launch
  nothing.
  """
  use ArbiterWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.MCP.Scope
  alias Arbiter.Release.UpdateCheck

  setup do
    home = Path.join(System.tmp_dir!(), "arb-rdc-#{System.unique_integer([:positive])}")
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
    name = UpdateCheck

    Req.Test.stub(
      name,
      &Req.Test.json(&1, %{"tag_name" => latest, "html_url" => "https://x.test"})
    )

    pid =
      start_supervised!(
        {UpdateCheck,
         enabled: true,
         repo: "acme/arbiter",
         running_version: running,
         initial_delay_ms: :infinity,
         req_options: [plug: {Req.Test, name}]}
      )

    Req.Test.allow(name, self(), pid)
    UpdateCheck.check_now()
  end

  defp as(token) do
    Phoenix.ConnTest.build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  defp operator_conn, do: as(Scope.mint_coordinator(nil, operator: true))
  defp session_conn, do: as(Scope.mint_coordinator(nil))

  describe "POST /api/release/deploy" do
    test "an operator starts the deploy of the latest release in its own unit" do
      start_checker("v99.0.0", "0.2.0")

      body = json_response(post(operator_conn(), "/api/release/deploy", %{}), 202)

      assert %{"tag" => "v99.0.0", "unit" => "arbiter-deploy-v99.0.0"} = body
      assert_received {:cmd, "systemd-run", args}
      assert "--unit=arbiter-deploy-v99.0.0" in args
      assert Enum.take(args, -5) == ["server", "deploy", "--version", "v99.0.0", "--json"]
    end

    test "an explicit version is deployed even when the checker is off" do
      body =
        json_response(post(operator_conn(), "/api/release/deploy", %{version: "v1.2.3"}), 202)

      assert body["tag"] == "v1.2.3"
    end

    test "nothing to do when already up to date and no version is named" do
      start_checker("v0.2.0", "0.2.0")

      conn = post(operator_conn(), "/api/release/deploy", %{})

      assert %{"error" => %{"type" => "conflict"}} = json_response(conn, 409)
      refute_received {:cmd, "systemd-run", _}
    end

    test "a version that is not a release tag is a 422 and launches nothing" do
      for bad <- ["main", "v1", "1.2.3", "v1.2.3 --force", "../v1.2.3"] do
        conn = post(operator_conn(), "/api/release/deploy", %{version: bad})
        assert %{"error" => %{"type" => type}} = json_response(conn, 422)
        assert type in ["invalid", "validation_error", "invalid_request"]
      end

      refute_received {:cmd, "systemd-run", _}
    end

    test "a second trigger while a deploy is running is refused (409)", %{home: home} do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      File.write!(
        Path.join(home, "deploy-status.json"),
        Jason.encode!(%{
          "state" => "running",
          "tag" => "v1.2.2",
          "pid" => System.pid(),
          "updated_at" => now
        })
      )

      conn = post(operator_conn(), "/api/release/deploy", %{version: "v1.2.3"})

      assert %{"error" => %{"type" => "conflict", "message" => message}} =
               json_response(conn, 409)

      assert message =~ "already"
      refute_received {:cmd, "systemd-run", _}
    end

    test "a coordinator session without operator proof is refused (403) and launches nothing" do
      conn = post(session_conn(), "/api/release/deploy", %{version: "v1.2.3"})

      assert json_response(conn, 403)
      refute_received {:cmd, _, _}
    end

    test "a worker, a refine token and an anonymous caller are refused" do
      worker = as(Scope.mint_worker(%{id: "bd-1", workspace_id: "ws-1"}))
      assert post(worker, "/api/release/deploy", %{version: "v1.2.3"}).status == 403

      refine = as(Scope.mint_refine("sess-1", "ws-1", "bd-1"))
      assert post(refine, "/api/release/deploy", %{version: "v1.2.3"}).status in [401, 403]

      anonymous = build_conn() |> put_req_header("content-type", "application/json")
      assert post(anonymous, "/api/release/deploy", %{version: "v1.2.3"}).status == 401

      refute_received {:cmd, _, _}
    end

    test "no secret reaches the response or the log" do
      System.put_env("GITHUB_TOKEN", "ghp_supersecrettokenvalue123")
      on_exit(fn -> System.delete_env("GITHUB_TOKEN") end)

      log =
        capture_log([level: :debug], fn ->
          conn = post(operator_conn(), "/api/release/deploy", %{version: "v1.2.3"})
          refute conn.resp_body =~ "ghp_supersecrettokenvalue123"
        end)

      refute log =~ "ghp_supersecrettokenvalue123"
    end
  end

  describe "GET /api/release/deploy" do
    test "reports no deploy, then the CLI's own record", %{home: home} do
      body = json_response(get(operator_conn(), "/api/release/deploy"), 200)
      assert body == %{"running" => false, "status" => nil}

      File.write!(
        Path.join(home, "deploy-status.json"),
        Jason.encode!(%{"state" => "succeeded", "tag" => "v1.2.3", "backup_path" => "/b"})
      )

      body = json_response(get(operator_conn(), "/api/release/deploy"), 200)

      assert %{"running" => false, "status" => %{"state" => "succeeded", "tag" => "v1.2.3"}} =
               body
    end

    test "is operator-only" do
      assert get(session_conn(), "/api/release/deploy").status == 403
    end
  end
end
