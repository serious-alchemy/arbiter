defmodule ArbiterWeb.DeployDismissTest do
  @moduledoc """
  The deploy-outcome banner's dismiss control: per deploy record, persisted in the
  installation settings, cosmetic only.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Settings

  setup do
    home = Path.join(System.tmp_dir!(), "arb-dd-#{System.unique_integer([:positive])}")
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

  defp finished(offset_s \\ 0),
    do: DateTime.utc_now() |> DateTime.add(offset_s) |> DateTime.to_iso8601()

  test "a succeeded banner has a dismiss control; dismissing hides it for good", %{
    conn: conn,
    home: home
  } do
    write_status(home, %{"state" => "succeeded", "tag" => "v9.0.0", "finished_at" => finished()})

    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#deploy-status #deploy-dismiss-form #deploy-dismiss-button")

    conn = post(conn, ~p"/release/deploy/dismiss", %{})
    assert redirected_to(conn) == "/"
    assert Settings.dismissed_deploy() != nil

    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#deploy-status")
    {:ok, view2, _} = live(build_conn() |> dashboard_login(), ~p"/")
    refute has_element?(view2, "#deploy-status")

    doc = conn |> get(~p"/about") |> html_response(200) |> LazyHTML.from_fragment()
    assert LazyHTML.query(doc, "#deploy-status") |> Enum.count() == 0
  end

  test "the next deploy's banner shows again", %{conn: conn, home: home} do
    write_status(home, %{
      "state" => "succeeded",
      "tag" => "v9.0.0",
      "finished_at" => finished(-60)
    })

    post(conn, ~p"/release/deploy/dismiss", %{})

    write_status(home, %{"state" => "succeeded", "tag" => "v9.1.0", "finished_at" => finished()})
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#deploy-status[data-state='succeeded']", "v9.1.0")
  end

  test "a failed outcome is not hidden by an earlier success's dismissal", %{
    conn: conn,
    home: home
  } do
    write_status(home, %{
      "state" => "succeeded",
      "tag" => "v9.0.0",
      "finished_at" => finished(-60)
    })

    post(conn, ~p"/release/deploy/dismiss", %{})

    for state <- ["failed", "rolled_back", "refused"] do
      write_status(home, %{"state" => state, "tag" => "v9.0.0", "finished_at" => finished()})
      {:ok, view, _} = live(conn, ~p"/")
      assert has_element?(view, "#deploy-status[data-state='#{state}']")
    end
  end

  test "a failed outcome can be dismissed deliberately", %{conn: conn, home: home} do
    write_status(home, %{"state" => "failed", "tag" => "v9.0.0", "finished_at" => finished()})
    post(conn, ~p"/release/deploy/dismiss", %{})
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#deploy-status")
  end

  test "a running deploy has no dismiss control and cannot be dismissed", %{
    conn: conn,
    home: home
  } do
    write_status(home, %{
      "state" => "running",
      "tag" => "v9.0.0",
      "pid" => System.pid(),
      "updated_at" => finished()
    })

    post(conn, ~p"/release/deploy/dismiss", %{})
    assert Settings.dismissed_deploy() == nil
  end
end
