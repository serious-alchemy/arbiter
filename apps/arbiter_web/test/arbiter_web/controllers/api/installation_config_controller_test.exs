defmodule ArbiterWeb.Api.InstallationConfigControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Settings
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @keys Arbiter.Settings.Registry.keys()

  setup do
    on_exit(fn ->
      Settings.set_conductor_system_max_concurrent(nil)
      Settings.set_credential_watchdog_adapters(nil)
      Settings.set_credential_watchdog_interval_ms(nil)
      Settings.set_credential_watchdog_recovery_interval_ms(nil)
      Settings.set_quota_providers_shown(nil)
      Settings.set_quota_providers_hidden(nil)
    end)

    :ok
  end

  describe "GET /api/installation/config" do
    test "lists every key with value, override flag and default", %{conn: conn} do
      %{"data" => data} = conn |> get("/api/installation/config") |> json_response(200)
      assert Enum.map(data, & &1["key"]) == @keys

      for item <- data do
        assert Map.has_key?(item, "value")
        assert Map.has_key?(item, "default")
        assert item["overridden"] == false
        assert item["override"] == nil
        assert is_binary(item["type"])
      end
    end

    test "reflects an override and supports ?key=", %{conn: conn} do
      {:ok, 5} = Settings.set_conductor_system_max_concurrent(5)

      assert %{"data" => %{"key" => "conductor_system_max_concurrent"} = item} =
               conn
               |> get("/api/installation/config", %{"key" => "conductor_system_max_concurrent"})
               |> json_response(200)

      assert item["value"] == 5
      assert item["override"] == 5
      assert item["overridden"] == true
      assert is_integer(item["default"])
    end

    test "unknown key is 404", %{conn: conn} do
      assert conn |> get("/api/installation/config", %{"key" => "nope"}) |> json_response(404)
    end
  end

  describe "PATCH /api/installation/config" do
    test "sets and clears a key", %{conn: conn} do
      body = %{"key" => "credential_watchdog_interval_ms", "value" => 1234}

      assert %{"data" => item} =
               conn |> patch("/api/installation/config", body) |> json_response(200)

      assert item["override"] == 1234
      assert Settings.credential_watchdog_interval_ms() == 1234

      body = %{"key" => "credential_watchdog_interval_ms", "value" => nil}

      assert %{"data" => item} =
               conn |> patch("/api/installation/config", body) |> json_response(200)

      assert item["overridden"] == false
      assert Settings.credential_watchdog_interval_ms() == nil
    end

    test "adapters keep nil, a list and [] distinct", %{conn: conn} do
      for {value, expected} <- [{["claude"], ["claude"]}, {[], []}, {nil, nil}] do
        body = %{"key" => "credential_watchdog_adapters", "value" => value}

        assert %{"data" => item} =
                 conn |> patch("/api/installation/config", body) |> json_response(200)

        assert item["override"] == expected
        assert Settings.credential_watchdog_adapters() == expected
      end
    end

    test "invalid value is 422 and changes nothing", %{conn: conn} do
      {:ok, 4} = Settings.set_conductor_system_max_concurrent(4)
      body = %{"key" => "conductor_system_max_concurrent", "value" => -2}
      resp = conn |> patch("/api/installation/config", body) |> json_response(422)
      assert resp["error"]["message"] =~ "positive integer"
      assert Settings.conductor_system_max_concurrent() == 4
    end

    test "unknown key and missing value are 422", %{conn: conn} do
      assert conn
             |> patch("/api/installation/config", %{"key" => "nope", "value" => 1})
             |> json_response(422)

      assert conn
             |> patch("/api/installation/config", %{"key" => "quota_providers_shown"})
             |> json_response(422)

      assert conn |> patch("/api/installation/config", %{"value" => 1}) |> json_response(422)
    end

    test "REST error and result match the MCP tool", %{conn: conn} do
      scope =
        Scope.mint_coordinator(nil)
        |> then(fn t ->
          {:ok, s} = Scope.from_token(t)
          s
        end)

      for {key, value} <- [
            {"conductor_system_max_concurrent", 0},
            {"credential_watchdog_adapters", ["bogus"]},
            {"quota_providers_hidden", "x"},
            {"conductor_system_max_concurrent", 6},
            {"credential_watchdog_adapters", []}
          ] do
        args = %{"key" => key, "value" => value}
        mcp = Tools.installation_config_set(scope, args)
        rest = conn |> patch("/api/installation/config", args)

        case mcp do
          {:error, {:invalid, msg}} ->
            assert json_response(rest, 422)["error"]["message"] == msg

          {:ok, %{value: v}} ->
            assert json_response(rest, 200)["data"]["override"] == v
        end
      end

      {:ok, mcp_get} = Tools.installation_config_get(scope, %{})
      %{"data" => data} = conn |> get("/api/installation/config") |> json_response(200)

      for item <- data,
          do:
            assert(
              item["override"] ==
                Map.fetch!(mcp_get.settings, String.to_existing_atom(item["key"]))
            )
    end
  end

  describe "operator-only keys (P-20, D-C-3)" do
    # One case per key class: the nodes.* enrolment keys (a URL, a boolean and
    # integers) and the two epic-floor scheduling switches.
    @operator_only_cases [
      {"nodes.public_url", "https://arb.tailnet.ts.net"},
      {"nodes.allow_public_endpoint", true},
      {"nodes.join_token_ttl_minutes", 30},
      {"nodes.fence_after_s", 45},
      {"nodes.lost_after_s", 120},
      {"scheduling_epic_floors_enabled", false},
      {"scheduling_max_lifted_in_flight", 2}
    ]

    setup do
      on_exit(fn ->
        for {key, _} <- @operator_only_cases, do: Arbiter.Settings.Registry.put(key, nil)
        Settings.set_scheduling_finish_first(nil)
      end)

      :ok
    end

    test "a coordinator-tier token without operator proof is refused, nothing written",
         %{conn: conn} do
      for {key, value} <- @operator_only_cases do
        resp = conn |> patch("/api/installation/config", %{"key" => key, "value" => value})

        assert %{"error" => %{"type" => "unauthorized", "message" => msg}} =
                 json_response(resp, 403)

        assert msg =~ key
        assert Arbiter.Settings.Registry.override(key) == nil
      end
    end

    test "a coordinator without proof still writes the ordinary keys", %{conn: conn} do
      body = %{"key" => "scheduling_finish_first", "value" => true}

      assert %{"data" => %{"override" => true}} =
               conn |> patch("/api/installation/config", body) |> json_response(200)
    end

    test "a coordinator token with operator proof may write them", %{conn: conn} do
      conn =
        put_req_header(
          conn,
          "authorization",
          "Bearer " <> Scope.mint_coordinator(nil, operator: true)
        )

      for {key, value} <- @operator_only_cases do
        assert %{"data" => %{"override" => ^value}} =
                 conn
                 |> patch("/api/installation/config", %{"key" => key, "value" => value})
                 |> json_response(200)
      end
    end
  end

  describe "nodes.registry_password (K8)" do
    test "is write-only over REST: the PATCH reply and every GET show a mask, never the secret",
         %{conn: conn} do
      on_exit(fn -> Arbiter.Settings.Registry.put("nodes.registry_password", nil) end)

      conn =
        put_req_header(
          conn,
          "authorization",
          "Bearer " <> Scope.mint_coordinator(nil, operator: true)
        )

      patched =
        conn
        |> patch("/api/installation/config", %{
          "key" => "nodes.registry_password",
          "value" => "12345-NEVER-ECHOED"
        })
        |> response(200)

      refute patched =~ "NEVER-ECHOED"

      assert %{"data" => %{"overridden" => true, "override" => "********"}} =
               Jason.decode!(patched)

      assert Settings.nodes_registry_password() == "12345-NEVER-ECHOED"

      for path <- [
            "/api/installation/config",
            "/api/installation/config?key=nodes.registry_password"
          ] do
        refute conn |> get(path) |> response(200) =~ "NEVER-ECHOED"
      end
    end
  end

  describe "authorisation" do
    test "no token is 401, a worker token is 403 on read and write" do
      anon = Phoenix.ConnTest.build_conn() |> Map.put(:remote_ip, {127, 0, 0, 1})
      assert anon |> get("/api/installation/config") |> json_response(401)

      n = System.unique_integer([:positive])
      {:ok, ws} = Ash.create(Workspace, %{name: "ic-ws-#{n}", prefix: "ic"})
      {:ok, task} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
      token = Scope.mint_worker(task)

      wconn =
        Phoenix.ConnTest.build_conn()
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("authorization", "Bearer #{token}")

      assert wconn |> get("/api/installation/config") |> json_response(403)

      body = %{"key" => "conductor_system_max_concurrent", "value" => 9}
      assert wconn |> patch("/api/installation/config", body) |> json_response(403)
      assert Settings.conductor_system_max_concurrent() == nil
    end
  end
end
