defmodule ArbiterCli.ClientAuthTest do
  @moduledoc """
  bd-asawcq: `/api` needs a bearer token, so `arb` always sends one. It uses
  `ARB_TOKEN` when set; otherwise, against this machine's server, it mints a
  coordinator token over the operator socket (bd-8381tk), once per
  invocation.

  async: false — these set and clear `ARB_TOKEN` / `ARB_HOST`, which every
  other `Client` caller in the VM would see.
  """
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Client
  alias ArbiterCli.FakeOperatorSocket
  alias ArbiterCli.Main

  @minted %{"token" => "minted-tok", "tier" => "coordinator", "expires_in" => 3600}

  setup do
    # A worker shell exports its own ARB_TOKEN; these tests decide it.
    saved = Map.new(~w(ARB_TOKEN ARB_HOST ARB_SESSION_ID ARB_SESSION_ROOT), &{&1, System.get_env(&1)})
    Enum.each(Map.keys(saved), &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    :ok
  end

  # Every request answers 200 `{"data": []}` and reports its Authorization
  # header to the test process.
  defp record_auth do
    owner = self()

    Req.Test.stub(Process.get(:bd2_stub_name), fn conn ->
      send(owner, {:auth, conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")})
      conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"data" => []})
    end)
  end

  defp auths do
    receive do
      {:auth, method, path, auth} -> [{method, path, auth} | auths()]
    after
      0 -> []
    end
  end

  describe "no ARB_TOKEN, loopback server" do
    test "mints over the operator socket and sends it as a bearer token" do
      FakeOperatorSocket.start!(@minted)
      record_auth()

      assert {:ok, _} = Client.get("/api/issues")

      assert_receive {:operator_request, %{"op" => "mint", "tier" => "coordinator"}}
      assert [{"GET", "/api/issues", ["Bearer minted-tok"]}] = auths()
    end

    test "mints once per invocation, however many requests it makes" do
      FakeOperatorSocket.start!(@minted)
      record_auth()

      for _ <- 1..3, do: assert({:ok, _} = Client.get("/api/issues"))

      assert_receive {:operator_request, _}
      refute_receive {:operator_request, _}
      assert Enum.all?(auths(), fn {_, _, auth} -> auth == ["Bearer minted-tok"] end)
    end

    test "re-mints once when the cached token has expired mid-run" do
      FakeOperatorSocket.start!(@minted)
      owner = self()
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Process.get(:bd2_stub_name), fn conn ->
        n = Agent.get_and_update(calls, &{&1, &1 + 1})
        send(owner, {:auth, conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")})

        if n == 0 do
          conn
          |> Plug.Conn.put_status(401)
          |> Req.Test.json(%{"error" => %{"message" => "Bearer token expired"}})
        else
          conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"data" => []})
        end
      end)

      assert {:ok, _} = Client.get("/api/issues")
      assert_receive {:operator_request, _}
      assert_receive {:operator_request, _}
      assert length(auths()) == 2
    end

    test "a refused mint sends the request unauthenticated and explains a 401" do
      FakeOperatorSocket.start!(%{
        "error" => %{"message" => "operator proof refused: spawned by arbiter", "reason" => "spawned_by_arbiter"}
      })

      Req.Test.stub(Process.get(:bd2_stub_name), fn conn ->
        send(self(), :noop)

        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"message" => "Authorization: Bearer <token> required"}})
      end)

      assert {:error, %Client.Error{status: 401, hint: hint}} = Client.get("/api/issues")
      assert hint =~ "spawned by arbiter"
      assert hint =~ "ARB_TOKEN"
    end

    test "an unreachable operator socket still lets anonymous routes through" do
      # CliCase points the socket at a path that does not exist.
      record_auth()
      assert {:ok, _} = Client.get("/api/version")
      assert [{"GET", "/api/version", []}] = auths()
    end
  end

  describe "ARB_TOKEN set" do
    test "is sent as-is and the operator socket is never asked" do
      FakeOperatorSocket.start!(@minted)
      System.put_env("ARB_TOKEN", "explicit-tok")
      record_auth()

      assert {:ok, _} = Client.get("/api/issues")

      refute_receive {:operator_request, _}
      assert [{"GET", "/api/issues", ["Bearer explicit-tok"]}] = auths()
    end
  end

  describe "a remote ARB_HOST" do
    test "never mints over this machine's socket" do
      FakeOperatorSocket.start!(@minted)
      System.put_env("ARB_HOST", "http://arbiter.example:4848")
      record_auth()

      assert {:ok, _} = Client.get("/api/issues")
      refute_receive {:operator_request, _}
      assert [{"GET", "/api/issues", []}] = auths()
    end
  end

  # AC: every `arb` verb works from the operator's shell with no ARB_TOKEN
  # (minted) and with ARB_TOKEN set. Every verb reaches the server through
  # `Client`, so this drives a spread of real verbs end to end and checks
  # that every request they make carries the expected bearer token.
  @verbs [
    ["ticket", "list"],
    ["ticket", "show", "bd-1"],
    ["ticket", "update", "bd-1", "--notes", "n"],
    ["ticket", "close", "bd-1"],
    ["dispatch", "bd-1"],
    ["inbox", "bd-1"],
    ["message", "send", "bd-1", "hello"],
    ["dep", "list"],
    ["workspace", "list"],
    ["worker", "list"],
    ["scheduler", "status"],
    ["prime"]
  ]

  defp run_verbs do
    for argv <- @verbs do
      _ = capture(fn -> Main.main(argv) end)
    end

    auths()
  end

  test "every verb authenticates with a minted token when ARB_TOKEN is unset" do
    FakeOperatorSocket.start!(@minted)
    record_auth()

    requests = run_verbs()

    assert length(requests) >= length(@verbs)
    assert Enum.all?(requests, fn {_, _, auth} -> auth == ["Bearer minted-tok"] end), inspect(requests)
  end

  test "every verb authenticates with ARB_TOKEN when it is set" do
    FakeOperatorSocket.start!(@minted)
    System.put_env("ARB_TOKEN", "explicit-tok")
    record_auth()

    requests = run_verbs()

    refute_receive {:operator_request, _}
    assert length(requests) >= length(@verbs)
    assert Enum.all?(requests, fn {_, _, auth} -> auth == ["Bearer explicit-tok"] end), inspect(requests)
  end
end
