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
end
