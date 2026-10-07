defmodule ArbiterCli.Cmd.SettingsTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Settings

  defp item(key, over) do
    Map.merge(
      %{
        "key" => key,
        "type" => "positive_integer",
        "description" => "desc of #{key}",
        "allowed" => nil,
        "value" => 16,
        "override" => nil,
        "overridden" => false,
        "default" => 16
      },
      over
    )
  end

  defp stub_config(items) do
    test_pid = self()

    stub_routes([
      {{"get", "/api/installation/config"},
       fn conn ->
         conn = Plug.Conn.fetch_query_params(conn)

         case conn.query_params["key"] do
           nil -> Req.Test.json(conn, %{"data" => items})
           k -> Req.Test.json(conn, %{"data" => Enum.find(items, &(&1["key"] == k))})
         end
       end},
      {{"patch", "/api/installation/config"},
       fn conn ->
         {:ok, raw, conn} = Plug.Conn.read_body(conn)
         send(test_pid, {:patched, Jason.decode!(raw)})

         case Jason.decode!(raw) do
           %{"key" => "nodes.public_url"} ->
             conn
             |> Plug.Conn.put_status(403)
             |> Req.Test.json(%{
               "error" => %{
                 "type" => "unauthorized",
                 "message" => "nodes.public_url is operator-only — it needs an operator-proof token"
               }
             })

           %{"value" => -1} ->
             conn
             |> Plug.Conn.put_status(422)
             |> Req.Test.json(%{
               "error" => %{
                 "type" => "validation_error",
                 "message" => "value must be a positive integer or null"
               }
             })

           %{"key" => k, "value" => v} ->
             Req.Test.json(conn, %{
               "data" => item(k, %{"override" => v, "overridden" => v != nil})
             })
         end
       end},
      {{"get", "/api/scheduler/status"}, fn conn -> Req.Test.json(conn, %{"paused" => true}) end}
    ])
  end

  defp items do
    [
      item("conductor_system_max_concurrent", %{
        "value" => 3,
        "override" => 3,
        "overridden" => true
      }),
      item("credential_watchdog_adapters", %{
        "type" => "agent_type_list",
        "value" => ["claude"],
        "default" => ["claude"]
      })
    ]
  end

  test "get lists value, source, default and autopilot (read-only)" do
    stub_config(items())
    {out, _err, 0} = capture(fn -> Settings.run(["get"]) end)
    assert out =~ "conductor_system_max_concurrent"
    assert out =~ "override"
    assert out =~ "default"
    assert out =~ "autopilot"
    assert out =~ "arb scheduler"
  end

  test "get <key> --json prints the REST item" do
    stub_config(items())

    {out, _err, 0} =
      capture(fn -> Settings.run(["get", "conductor_system_max_concurrent", "--json"]) end)

    assert %{"data" => %{"override" => 3}} = Jason.decode!(out)
  end

  test "set parses integers, JSON lists, [] and null" do
    stub_config(items())

    for {raw, expected} <- [{"5", 5}, {"[\"claude\"]", ["claude"]}, {"[]", []}, {"null", nil}] do
      {_out, _err, 0} =
        capture(fn -> Settings.run(["set", "credential_watchdog_adapters", raw]) end)

      assert_received {:patched, %{"key" => "credential_watchdog_adapters", "value" => ^expected}}
    end
  end

  test "unset sends null" do
    stub_config(items())

    {_out, _err, 0} =
      capture(fn -> Settings.run(["unset", "conductor_system_max_concurrent"]) end)

    assert_received {:patched, %{"key" => "conductor_system_max_concurrent", "value" => nil}}
  end

  test "a rejected value prints the server's message and exits non-zero" do
    stub_config(items())

    {_out, err, code} =
      capture(fn -> Settings.run(["set", "conductor_system_max_concurrent", "-1"]) end)

    assert code != 0
    assert err =~ "positive integer"
  end

  test "an operator-only key refused by the server prints its message, exits non-zero (P-20)" do
    stub_config(items())

    {_out, err, code} =
      capture(fn -> Settings.run(["set", "nodes.public_url", "https://x.ts.net"]) end)

    assert code != 0
    assert err =~ "operator-only"
  end

  test "set uses the shared value rule: a quoted string stays a string" do
    stub_config(items())
    capture(fn -> Settings.run(["set", "nodes.public_url", ~s("true")]) end)
    # (refused by the stub, but the body shows how the value was typed)
    assert_received {:patched, %{"key" => "nodes.public_url", "value" => "true"}}
  end

  test "set without a value and unknown subcommands die" do
    stub_config(items())
    {_o, err, code} = capture(fn -> Settings.run(["set", "conductor_system_max_concurrent"]) end)
    assert code != 0 and err =~ "requires"
    {_o, err, code} = capture(fn -> Settings.run(["bogus"]) end)
    assert code != 0 and err =~ "unknown"
  end

  test "schema lists keys, types and allowed values" do
    stub_config([
      item("credential_watchdog_adapters", %{
        "type" => "agent_type_list",
        "allowed" => ["claude", "codex"]
      })
    ])

    {out, _err, 0} = capture(fn -> Settings.run(["schema"]) end)
    assert out =~ "credential_watchdog_adapters"
    assert out =~ "agent_type_list"
    assert out =~ "codex"
  end

  test "--help lists the subcommands" do
    {out, _err, 0} = capture(fn -> Settings.run(["--help"]) end)
    for sub <- ~w(get set unset schema), do: assert(out =~ "arb settings #{sub}")
  end

  describe "flag strictness (bd-cqw11s)" do
    test "`set <k> <v> --force` is rejected instead of storing \"v --force\"" do
      {_out, err, code} =
        capture(fn -> Settings.run(["set", "nodes.public_url", "https://x", "--force"]) end)

      assert code == 1
      assert err =~ "unknown option --force for arb settings"
    end

    test "`get --foo` is rejected rather than querying a key named --foo" do
      {_out, err, code} = capture(fn -> Settings.run(["get", "--foo"]) end)

      assert code == 1
      assert err =~ "unknown option --foo for arb settings"
    end
  end
end
