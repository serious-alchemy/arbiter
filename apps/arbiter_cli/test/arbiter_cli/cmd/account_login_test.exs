defmodule ArbiterCli.Cmd.AccountLoginTest do
  @moduledoc """
  `arb account login <ref>` (bd-bh50vs): starts a login over `/api/accounts/:ref/login`,
  prints the sign-in URL / device code, reads a needed code from a HIDDEN prompt
  and relays it in the request body, and exits non-zero on anything but success.
  """
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Account

  @url "https://claude.com/cai/oauth/authorize?code=true&state=FAKE"
  @secret "PASTED-CODE-8675309"

  defp state(status, extra \\ %{}) do
    Map.merge(
      %{
        "id" => "login-1",
        "provider" => "claude",
        "account" => "work",
        "status" => status,
        "url" => nil,
        "device_code" => nil,
        "needs_paste" => false,
        "reason" => nil
      },
      extra
    )
  end

  # A scripted server: `states` are returned by successive GETs (the last one
  # repeats); every POST body the CLI sends is mailed to the test.
  defp serve(states) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> states end)

    stub_routes([
      {{"post", "/api/accounts/claude:work/login"},
       fn conn ->
         conn |> Plug.Conn.put_status(201) |> Req.Test.json(state("starting"))
       end},
      {{"get", "/api/account_logins/login-1"},
       fn conn ->
         body =
           Agent.get_and_update(agent, fn
             [last] -> {last, [last]}
             [head | rest] -> {head, rest}
           end)

         conn |> Plug.Conn.put_status(200) |> Req.Test.json(body)
       end},
      {{"post", "/api/account_logins/login-1/paste"},
       fn conn ->
         {:ok, raw, conn} = Plug.Conn.read_body(conn)
         send(test, {:paste, conn.query_string, raw})
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(state("verifying"))
       end},
      {{"post", "/api/account_logins/login-1/cancel"},
       fn conn ->
         send(test, :cancelled)
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(state("cancelled"))
       end}
    ])
  end

  setup do
    Process.put(:bd2_login_poll_ms, 1)
    test = self()

    Process.put(:bd2_login_prompt, fn prompt ->
      send(test, {:prompt, prompt})
      @secret
    end)

    :ok
  end

  test "paste flow: prints the URL, reads the code from the hidden prompt, exits 0" do
    serve([
      state("starting"),
      state("awaiting_user", %{"url" => @url, "needs_paste" => true}),
      state("verifying"),
      state("succeeded")
    ])

    {out, _err, exit_code} = capture(fn -> Account.run(["login", "claude:work"]) end)

    assert exit_code == 0
    assert out =~ @url
    assert out =~ "logged in"
    assert_received {:prompt, _}

    # the code went in the JSON body — never the query string — and is not echoed
    assert_received {:paste, "", body}
    assert Jason.decode!(body) == %{"code" => @secret}
    refute out =~ @secret
  end

  test "the code is never read from argv and a code in argv is refused" do
    serve([state("awaiting_user", %{"url" => @url, "needs_paste" => true}), state("succeeded")])

    {_out, err, exit_code} =
      capture(fn -> Account.run(["login", "claude:work", "--code", @secret]) end)

    assert exit_code != 0
    assert err =~ "--code"
    refute_received {:paste, _, _}
  end

  test "device-code flow prints the code and never prompts" do
    serve([
      state("awaiting_user", %{
        "url" => "https://auth.openai.com/codex/device",
        "device_code" => "ABCD-12345"
      }),
      state("succeeded")
    ])

    {out, _err, exit_code} = capture(fn -> Account.run(["login", "claude:work"]) end)

    assert exit_code == 0
    assert out =~ "https://auth.openai.com/codex/device"
    assert out =~ "ABCD-12345"
    refute_received {:prompt, _}
  end

  for status <- ["failed", "timed_out", "cancelled"] do
    test "#{status} exits non-zero with the reason" do
      serve([
        state("awaiting_user", %{"url" => @url, "needs_paste" => true}),
        state("verifying"),
        state(unquote(status), %{"reason" => "the CLI said no"})
      ])

      {_out, err, exit_code} = capture(fn -> Account.run(["login", "claude:work"]) end)

      assert exit_code != 0
      assert err =~ unquote(String.replace(status, "_", " "))
      assert err =~ "the CLI said no"
    end
  end

  test "an empty code cancels the login instead of sending it" do
    serve([state("awaiting_user", %{"url" => @url, "needs_paste" => true}), state("cancelled")])
    Process.put(:bd2_login_prompt, fn _ -> "" end)

    {_out, _err, exit_code} = capture(fn -> Account.run(["login", "claude:work"]) end)

    assert exit_code != 0
    assert_received :cancelled
    refute_received {:paste, _, _}
  end

  test "requires a ref" do
    {_out, err, exit_code} = capture(fn -> Account.run(["login"]) end)
    assert exit_code != 0
    assert err =~ "ref"
  end
end
