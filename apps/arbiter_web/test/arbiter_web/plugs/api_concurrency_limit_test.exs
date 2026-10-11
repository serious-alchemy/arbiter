defmodule ArbiterWeb.Plugs.ApiConcurrencyLimitTest do
  @moduledoc """
  bd-66anxj: a burst of `/api` requests over the configured limit is refused
  with a fast 503 + `Retry-After`, and the slots free up so the server keeps
  serving within the limit.
  """
  use ArbiterWeb.ConnCase, async: false

  import Plug.Conn

  alias ArbiterWeb.Plugs.ApiConcurrencyLimit

  setup do
    prev = Application.get_env(:arbiter_web, :api_max_concurrency)
    Application.put_env(:arbiter_web, :api_max_concurrency, 2)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:arbiter_web, :api_max_concurrency, prev),
        else: Application.delete_env(:arbiter_web, :api_max_concurrency)
    end)

    :ok
  end

  # Holds a slot from a separate process until told to release.
  defp hold_slot do
    parent = self()

    pid =
      spawn_link(fn ->
        conn = ApiConcurrencyLimit.call(Phoenix.ConnTest.build_conn(:get, "/api/x"), [])
        send(parent, {:held, self(), conn.halted})

        receive do
          :release -> :ok
        end
      end)

    assert_receive {:held, ^pid, halted}
    {pid, halted}
  end

  test "requests over the limit get a fast 503 with Retry-After; slots free up" do
    {p1, false} = hold_slot()
    {p2, false} = hold_slot()
    {p3, true} = hold_slot()

    conn = ApiConcurrencyLimit.call(Phoenix.ConnTest.build_conn(:get, "/api/x"), [])
    assert conn.halted
    assert conn.status == 503
    assert [_] = get_resp_header(conn, "retry-after")
    assert %{"error" => %{"type" => "busy"}} = Jason.decode!(conn.resp_body)

    ref = Process.monitor(p1)
    send(p1, :release)
    assert_receive {:DOWN, ^ref, :process, ^p1, _}

    # The released slot is reusable (the limiter drops dead holders).
    _ = :sys.get_state(ApiConcurrencyLimit.Counter)
    {p4, false} = hold_slot()

    for p <- [p2, p3, p4], do: send(p, :release)
  end

  test "a response releases the slot" do
    conn = ApiConcurrencyLimit.call(Phoenix.ConnTest.build_conn(:get, "/api/x"), [])
    refute conn.halted
    conn |> send_resp(200, "ok")
    _ = :sys.get_state(ApiConcurrencyLimit.Counter)
    assert ApiConcurrencyLimit.in_flight() == 0
  end

  test "the SSE event stream is exempt" do
    for _ <- 1..3, do: hold_slot()
    conn = ApiConcurrencyLimit.call(Phoenix.ConnTest.build_conn(:get, "/api/events"), [])
    refute conn.halted
  end
end
