defmodule ArbiterWeb.Api.ProviderPauseControllerTest do
  @moduledoc "bd-5ef587: `/api/providers/pause|resume|paused` back `arb provider`."
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Providers.Pause

  test "pause, list and resume round-trip", %{conn: conn} do
    conn1 = post(conn, "/api/providers/pause", %{"ref" => "codex", "reason" => "jail escape"})

    assert %{"paused" => [%{"target" => "codex", "reason" => "jail escape"}]} =
             json_response(conn1, 200)

    assert Pause.provider_paused?(:codex)

    assert %{"paused" => [%{"target" => "codex"}]} =
             json_response(get(conn, "/api/providers/paused"), 200)

    assert %{"paused" => []} =
             json_response(post(conn, "/api/providers/resume", %{"ref" => "codex"}), 200)

    refute Pause.provider_paused?(:codex)
  end

  test "an unknown ref is 404 and resuming something not paused is 4xx", %{conn: conn} do
    assert json_response(post(conn, "/api/providers/pause", %{"ref" => "nope"}), 404)
    assert json_response(post(conn, "/api/providers/resume", %{"ref" => "claude"}), 400)
  end

  test "an ambiguous ref explains provider:slug and a non-string reason is rejected",
       %{conn: conn} do
    assert json_response(
             post(conn, "/api/providers/pause", %{"ref" => "codex", "reason" => 5}),
             400
           )

    refute Pause.provider_paused?(:codex)
  end

  test "attribution comes from the token scope, not a literal", %{conn: conn} do
    assert %{"paused" => [%{"by" => by}]} =
             json_response(
               post(conn, "/api/providers/pause", %{"ref" => "codex", "by" => "spoof"}),
               200
             )

    refute by in ["api", "spoof"]
  end

  test "a missing ref is rejected", %{conn: conn} do
    assert json_response(post(conn, "/api/providers/pause", %{}), 400)
  end
end
