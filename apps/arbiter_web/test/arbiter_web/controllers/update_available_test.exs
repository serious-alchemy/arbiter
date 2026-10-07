defmodule ArbiterWeb.UpdateAvailableTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Release.UpdateCheck

  defp start_checker(body, running_version) do
    Req.Test.stub(UpdateCheck, &Req.Test.json(&1, body))

    pid =
      start_supervised!(
        {UpdateCheck,
         enabled: true,
         repo: "acme/arbiter",
         running_version: running_version,
         initial_delay_ms: :infinity,
         req_options: [plug: {Req.Test, UpdateCheck}]}
      )

    Req.Test.allow(UpdateCheck, self(), pid)
    UpdateCheck.check_now()
  end

  test "GET /api/version reports the update block when an update exists", %{conn: conn} do
    start_checker(%{"tag_name" => "v99.0.0", "html_url" => "https://example.test/r"}, "0.2.0")

    body =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/api/version")
      |> json_response(200)

    assert %{"update_available" => true, "latest" => "v99.0.0", "enabled" => true, "error" => nil} =
             body["update"]

    assert body["update"]["release_url"] == "https://example.test/r"
  end

  test "GET /api/version reports the release repo the install takes releases from", %{conn: conn} do
    previous = System.get_env("ARB_RELEASE_REPO")
    System.put_env("ARB_RELEASE_REPO", "acme/arbiter")

    on_exit(fn ->
      if previous,
        do: System.put_env("ARB_RELEASE_REPO", previous),
        else: System.delete_env("ARB_RELEASE_REPO")
    end)

    body =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/api/version")
      |> json_response(200)

    assert body["release_repo"] == "acme/arbiter"
  end

  test "GET /api/version reports disabled when the checker is not running", %{conn: conn} do
    body =
      conn
      |> put_req_header("accept", "application/json")
      |> get(~p"/api/version")
      |> json_response(200)

    assert %{"enabled" => false, "update_available" => false} = body["update"]
  end

  test "home page shows the banner with release link and deploy command", %{conn: conn} do
    start_checker(%{"tag_name" => "v99.0.0", "html_url" => "https://example.test/r"}, "0.2.0")

    html = conn |> get(~p"/about") |> html_response(200)
    doc = LazyHTML.from_fragment(html)

    assert Enum.count(LazyHTML.query(doc, "#update-available")) == 1

    assert LazyHTML.attribute(LazyHTML.query(doc, "#update-release-link"), "href") == [
             "https://example.test/r"
           ]

    assert LazyHTML.text(LazyHTML.query(doc, "#update-deploy-command")) == "arb server deploy"
  end

  test "home page has no banner when up to date", %{conn: conn} do
    start_checker(%{"tag_name" => "v0.2.0"}, "0.2.0")

    doc = conn |> get(~p"/about") |> html_response(200) |> LazyHTML.from_fragment()
    assert LazyHTML.query(doc, "#update-available") |> Enum.count() == 0
  end

  describe "shared layout" do
    test "the board shows the update notice", %{conn: conn} do
      start_checker(%{"tag_name" => "v99.0.0", "html_url" => "https://example.test/r"}, "0.2.0")

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#update-available")
      assert has_element?(view, "#update-release-link[href='https://example.test/r']")
      assert has_element?(view, "#update-deploy-command", "arb server deploy")
    end

    test "another LiveView page shows the update notice too", %{conn: conn} do
      start_checker(%{"tag_name" => "v99.0.0"}, "0.2.0")

      {:ok, view, _html} = live(conn, ~p"/tasks")
      assert has_element?(view, "#update-available")
    end

    test "the board renders nothing extra when up to date", %{conn: conn} do
      start_checker(%{"tag_name" => "v0.2.0"}, "0.2.0")

      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#update-available")
    end

    test "the layout links to /about", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#about-link[href='/about']")
    end
  end

  describe "operator self-update (bd-6umf7z)" do
    setup do
      home = Path.join(System.tmp_dir!(), "arb-ua-#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      previous = Application.fetch_env(:arbiter, :data_dir)
      Application.put_env(:arbiter, :data_dir, home)

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:arbiter, :data_dir, v)
          :error -> Application.delete_env(:arbiter, :data_dir)
        end

        File.rm_rf(home)
      end)

      {:ok, home: home}
    end

    defp write_status(home, status),
      do: File.write!(Path.join(home, "deploy-status.json"), Jason.encode!(status))

    defp start_checker_with(body, running_version, applied) do
      Req.Test.stub(UpdateCheck, fn conn ->
        case conn.request_path do
          "/m.txt" -> Plug.Conn.send_resp(conn, 200, "20260101000000_a\n20260202000000_b\n")
          _ -> Req.Test.json(conn, body)
        end
      end)

      pid =
        start_supervised!(
          {UpdateCheck,
           enabled: true,
           repo: "acme/arbiter",
           running_version: running_version,
           initial_delay_ms: :infinity,
           applied_migrations: applied,
           req_options: [plug: {Req.Test, UpdateCheck}]}
        )

      Req.Test.allow(UpdateCheck, self(), pid)
      UpdateCheck.check_now()
    end

    @release %{
      "tag_name" => "v99.0.0",
      "html_url" => "https://example.test/r",
      "assets" => [
        %{
          "name" => "arbiter-v99.0.0-migrations.txt",
          "browser_download_url" => "https://dl.test/m.txt"
        }
      ]
    }

    test "a dashboard session sees 'Update to vX' with the release notes link, on a dead page", %{
      conn: conn
    } do
      start_checker_with(@release, "0.2.0", fn -> [] end)

      doc = conn |> get(~p"/about") |> html_response(200) |> LazyHTML.from_fragment()

      assert LazyHTML.text(LazyHTML.query(doc, "#update-deploy-button")) =~ "Update to v99.0.0"

      assert LazyHTML.attribute(LazyHTML.query(doc, "#update-deploy-form"), "action") == [
               "/release/deploy"
             ]

      assert LazyHTML.attribute(LazyHTML.query(doc, "#update-release-link"), "href") != []
      # A real POST form: CSRF-protected.
      assert LazyHTML.query(doc, "#update-deploy-form input[name=_csrf_token]") |> Enum.count() ==
               1
    end

    test "and in a LiveView page", %{conn: conn} do
      start_checker_with(@release, "0.2.0", fn -> [] end)

      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(view, "#update-deploy-form[action='/release/deploy']")
      assert has_element?(view, "#update-deploy-button", "Update to v99.0.0")
      assert has_element?(view, "#update-deploy-form input[name=_csrf_token]")
    end

    test "no button when up to date", %{conn: conn} do
      start_checker_with(%{"tag_name" => "v0.2.0"}, "0.2.0", fn -> [] end)

      {:ok, view, _} = live(conn, ~p"/")
      refute has_element?(view, "#update-deploy-button")
      refute has_element?(view, "#update-deploy-form")
    end

    test "the confirmation names the version and the pending migrations", %{conn: conn} do
      start_checker_with(@release, "0.2.0", fn -> [20_260_101_000_000] end)

      {:ok, view, _} = live(conn, ~p"/")
      confirm = view |> element("#update-deploy-button") |> render() |> confirm_text()

      assert confirm =~ "v99.0.0"
      assert confirm =~ "1 pending migration"
      assert confirm =~ "20260202000000_b"
      assert confirm =~ "database backup"
    end

    test "the confirmation says so when no migrations are pending", %{conn: conn} do
      start_checker_with(@release, "0.2.0", fn -> [20_260_101_000_000, 20_260_202_000_000] end)

      {:ok, view, _} = live(conn, ~p"/")
      confirm = view |> element("#update-deploy-button") |> render() |> confirm_text()

      assert confirm =~ "v99.0.0"
      assert confirm =~ "no pending migrations"
    end

    test "the confirmation is honest when migrations cannot be determined", %{conn: conn} do
      start_checker_with(%{"tag_name" => "v99.0.0"}, "0.2.0", fn -> [] end)

      {:ok, view, _} = live(conn, ~p"/")
      confirm = view |> element("#update-deploy-button") |> render() |> confirm_text()

      assert confirm =~ "v99.0.0"
      assert confirm =~ "could not be determined"
    end

    test "no button while a deploy is running, but the progress is shown", %{
      conn: conn,
      home: home
    } do
      start_checker_with(@release, "0.2.0", fn -> [] end)

      write_status(home, %{
        "state" => "running",
        "tag" => "v99.0.0",
        "phase" => "restarting",
        "pid" => System.pid(),
        "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

      {:ok, view, _} = live(conn, ~p"/")

      refute has_element?(view, "#update-deploy-button")
      assert has_element?(view, "#deploy-status[data-state='running']", "v99.0.0")
      assert has_element?(view, "#deploy-status", "restarting")
    end

    test "after the restart the outcome is shown: success", %{conn: conn, home: home} do
      start_checker_with(%{"tag_name" => "v0.2.0"}, "0.2.0", fn -> [] end)

      write_status(home, %{
        "state" => "succeeded",
        "tag" => "v99.0.0",
        "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "backup_path" => "/h/snapshots/arbiter-pre-v99.0.0-x.sqlite3"
      })

      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(view, "#deploy-status[data-state='succeeded']", "v99.0.0")
      assert has_element?(view, "#deploy-status", "arbiter-pre-v99.0.0-x.sqlite3")
    end

    test "after the restart the outcome is shown: rollback, with the restored database", %{
      conn: conn,
      home: home
    } do
      start_checker_with(@release, "0.2.0", fn -> [] end)

      write_status(home, %{
        "state" => "rolled_back",
        "tag" => "v99.0.0",
        "rolled_back_to" => "v0.2.0",
        "restored_database" => true,
        "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "backup_path" => "/h/snapshots/b.sqlite3"
      })

      {:ok, view, _} = live(conn, ~p"/")

      assert has_element?(view, "#deploy-status[data-state='rolled_back']", "v0.2.0")
      assert has_element?(view, "#deploy-status", "database was restored")
      # The update is still on offer to retry.
      assert has_element?(view, "#update-deploy-button")
    end

    test "an old successful deploy is not shown forever", %{conn: conn, home: home} do
      start_checker_with(%{"tag_name" => "v0.2.0"}, "0.2.0", fn -> [] end)
      old = DateTime.utc_now() |> DateTime.add(-3 * 86_400) |> DateTime.to_iso8601()
      write_status(home, %{"state" => "succeeded", "tag" => "v0.2.0", "finished_at" => old})

      {:ok, view, _} = live(conn, ~p"/")
      refute has_element?(view, "#deploy-status")
    end

    test "a failed (pre-swap) deploy is shown", %{conn: conn, home: home} do
      start_checker_with(%{"tag_name" => "v0.2.0"}, "0.2.0", fn -> [] end)

      write_status(home, %{
        "state" => "failed",
        "tag" => "v99.0.0",
        "message" => "database backup failed",
        "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#deploy-status[data-state='failed']", "database backup failed")
    end

    test "a deploy refused before it began (active workers) is shown with its reason",
         %{conn: conn, home: home} do
      start_checker_with(%{"tag_name" => "v99.0.0"}, "0.2.0", fn -> [] end)

      write_status(home, %{
        "state" => "failed",
        "tag" => "v99.0.0",
        "phase" => "preflight",
        "message" => "1 worker(s) are actively working: bd-xyz",
        "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#deploy-status[data-state='failed']", "actively working")
      assert has_element?(view, "#update-deploy-button")
    end

    defp confirm_text(html) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("data-confirm")
      |> List.first()
    end
  end
end
