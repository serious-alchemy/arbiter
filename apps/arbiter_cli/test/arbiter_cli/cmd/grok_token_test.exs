defmodule ArbiterCli.Cmd.GrokTokenTest do
  @moduledoc """
  `arb grok-token` (bd-9p4lx9): a grok worker's `GROK_AUTH_PROVIDER_COMMAND`.
  """
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.GrokToken

  setup do
    on_exit(fn -> System.delete_env("GROK_AUTH_EXPIRED") end)
    :ok
  end

  test "prints the access token and lifetime as one JSON object on stdout" do
    stub_post("/api/grok/token", %{"access_token" => "tok-abc", "expires_in" => 21_000}, 200)

    {out, err, code} = capture(fn -> GrokToken.run([]) end)

    assert code == 0
    assert err == ""
    assert Jason.decode!(out) == %{"access_token" => "tok-abc", "expires_in" => 21_000}
  end

  test "GROK_AUTH_EXPIRED=1 asks the server to force a refresh" do
    test_pid = self()
    name = Process.get(:bd2_stub_name)

    Req.Test.stub(name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})
      Req.Test.json(conn, %{"access_token" => "t", "expires_in" => 60})
    end)

    System.put_env("GROK_AUTH_EXPIRED", "1")
    capture(fn -> GrokToken.run([]) end)
    assert_received {:body, %{"force" => true}}

    System.delete_env("GROK_AUTH_EXPIRED")
    capture(fn -> GrokToken.run([]) end)
    assert_received {:body, %{"force" => false}}
  end

  test "a server refusal prints the reason on stderr, nothing on stdout, and exits 1" do
    stub_post(
      "/api/grok/token",
      %{
        "error" => %{
          "type" => "grok_reauth_required",
          "message" => "Run `grok login --device-code` on the Arbiter host.",
          "details" => %{}
        }
      },
      503
    )

    {out, err, code} = capture(fn -> GrokToken.run([]) end)

    assert code == 1
    assert out == ""
    assert err =~ "grok login"
  end

  test "a reply with no token is an error, not an empty success" do
    stub_post("/api/grok/token", %{"expires_in" => 60}, 200)

    {out, err, code} = capture(fn -> GrokToken.run([]) end)

    assert code == 1
    assert out == ""
    assert err =~ "no access_token"
  end
end
