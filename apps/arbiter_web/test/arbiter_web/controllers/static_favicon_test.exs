defmodule ArbiterWeb.StaticFaviconTest do
  use ArbiterWeb.ConnCase, async: true

  @digested "favicon-0123456789abcdef0123456789abcdef.svg"
  @stray "faviconx-notes.txt"

  setup do
    dir = Application.app_dir(:arbiter_web, "priv/static")
    paths = for name <- [@digested, @stray], do: Path.join(dir, name)
    for p <- paths, do: File.write!(p, "<svg xmlns=\"http://www.w3.org/2000/svg\"/>")
    on_exit(fn -> Enum.each(paths, &File.rm/1) end)
    :ok
  end

  test "digested root favicon (phx.digest output) is served", %{conn: conn} do
    conn = get(conn, "/" <> @digested)
    assert response(conn, 200)
    assert [ct] = get_resp_header(conn, "content-type")
    assert ct =~ "image/svg+xml"
  end

  test "undigested favicons still served", %{conn: conn} do
    assert get(conn, "/favicon.svg").status == 200
    assert get(conn, "/favicon.ico").status == 200
  end

  test "unrelated root files are not served", %{conn: conn} do
    refute get(conn, "/mix.exs").status == 200
    assert get(conn, "/" <> @stray).status == 404
  end
end
