defmodule ArbiterWeb.UpdateDismissTest do
  @moduledoc """
  The update banner's dismiss control: per-version, persisted in the installation
  settings, cosmetic only.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Release.UpdateCheck
  alias Arbiter.Settings

  defp start_checker(latest, running \\ "0.2.0") do
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

  test "the banner has a dismiss control", %{conn: conn} do
    start_checker("v99.0.0")
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#update-dismiss-form #update-dismiss-button")
  end

  test "dismissing hides the banner, persists, and survives a reload", %{conn: conn} do
    start_checker("v99.0.0")

    conn = post(conn, ~p"/release/update/dismiss", %{})
    assert redirected_to(conn) == "/"
    assert Settings.dismissed_update_version() == "v99.0.0"

    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#update-available")
    {:ok, view2, _} = live(build_conn() |> dashboard_login(), ~p"/")
    refute has_element?(view2, "#update-available")
  end

  test "a newer version brings the banner back", %{conn: conn} do
    start_checker("v99.0.0")
    post(conn, ~p"/release/update/dismiss", %{})
    stop_supervised!(UpdateCheck)

    start_checker("v99.1.0")
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#update-available")
  end

  test "dismissal is cosmetic: /about still offers the update and /api/version reports it",
       %{conn: conn} do
    start_checker("v99.0.0")
    post(conn, ~p"/release/update/dismiss", %{})

    doc = conn |> get(~p"/about") |> html_response(200) |> LazyHTML.from_fragment()
    assert LazyHTML.query(doc, "#update-available") |> Enum.count() == 1

    body =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get(~p"/api/version")
      |> json_response(200)

    assert body["update"]["update_available"] == true
  end

  test "with no update available dismissing stores nothing", %{conn: conn} do
    start_checker("v0.2.0")
    post(conn, ~p"/release/update/dismiss", %{})
    assert Settings.dismissed_update_version() == nil
  end

  describe "in-place dismissal (no page load)" do
    test "submitting the dismiss form hides the banner without a redirect", %{conn: conn} do
      start_checker("v99.0.0")
      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#update-available")

      view |> element("#update-dismiss-form") |> render_submit()

      refute has_element?(view, "#update-available")
      assert Settings.dismissed_update_version() == "v99.0.0"

      {:ok, reloaded, _} = live(conn, ~p"/")
      refute has_element?(reloaded, "#update-available")
      # Let the chrome's mount-time async loads finish before the test exits.
      render_async(view)
      render_async(reloaded)
    end

    test "other connected LiveViews hide the banner over PubSub", %{conn: conn} do
      start_checker("v99.0.0")
      {:ok, view, _} = live(conn, ~p"/")
      {:ok, other, _} = live(build_conn() |> dashboard_login(), ~p"/audit")
      assert has_element?(other, "#update-available")

      view |> element("#update-dismiss-form") |> render_submit()

      _ = render(other)
      refute has_element?(other, "#update-available")
      render_async(view)
      render_async(other)
    end

    test "controller-rendered pages keep the POST fallback form", %{conn: conn} do
      start_checker("v99.0.0")
      doc = conn |> get(~p"/about") |> html_response(200) |> LazyHTML.from_fragment()

      assert LazyHTML.query(doc, "#update-dismiss-form[action='/release/update/dismiss']")
             |> Enum.count() == 1
    end
  end
end
