defmodule ArbiterWeb.Api.WorkspaceOperationsTest do
  @moduledoc """
  P-21 REST surface: `worker_env` writes, `config_schema`, atomic standing
  orders — and the no-secret-value rule across every machine response.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Workspace

  @secret_value "tok_p21_SUPERSECRET_value"
  @plain_value "plain-env-value-p21"

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  defp workspace(attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Workspace, Map.merge(%{name: "p21-#{n}", prefix: "pt"}, attrs))
    ws
  end

  describe "worker_env over REST" do
    test "PATCH sets, toggles and removes; responses carry names + flags only", %{conn: conn} do
      ws = workspace()

      body =
        conn
        |> patch(~p"/api/workspaces/#{ws.id}", %{
          worker_env: %{
            "API_TOKEN" => %{"value" => @secret_value, "secret" => true},
            "LOG_LEVEL" => %{"value" => @plain_value}
          }
        })
        |> json_response(200)

      assert body["worker_env"] == [
               %{"name" => "API_TOKEN", "secret" => true},
               %{"name" => "LOG_LEVEL", "secret" => false}
             ]

      {:ok, stored} = Ash.get(Workspace, ws.id)
      assert Workspace.worker_env_map(stored) == %{"API_TOKEN" => @secret_value, "LOG_LEVEL" => @plain_value}

      body =
        conn
        |> patch(~p"/api/workspaces/#{ws.id}", %{worker_env: %{"LOG_LEVEL" => %{"secret" => true}}})
        |> json_response(200)

      assert %{"name" => "LOG_LEVEL", "secret" => true} in body["worker_env"]

      body =
        conn
        |> patch(~p"/api/workspaces/#{ws.id}", %{worker_env: %{"API_TOKEN" => nil}})
        |> json_response(200)

      assert body["worker_env"] == [%{"name" => "LOG_LEVEL", "secret" => true}]
    end

    test "an invalid name is a 422", %{conn: conn} do
      ws = workspace()

      conn = patch(conn, ~p"/api/workspaces/#{ws.id}", %{worker_env: %{"9bad" => %{"value" => "x"}}})
      assert %{"error" => %{"type" => "validation_error"}} = json_response(conn, 422)
    end

    test "create accepts worker_env too", %{conn: conn} do
      body =
        conn
        |> post(~p"/api/workspaces", %{
          name: "p21-created",
          worker_env: %{"X" => %{"value" => @secret_value, "secret" => true}}
        })
        |> json_response(201)

      assert body["worker_env"] == [%{"name" => "X", "secret" => true}]
      assert body["prefix"] == "ar"
    end
  end

  # AC2: no secret VALUE in any machine response.
  describe "no secret value appears in a machine response" do
    test "REST show / index / create / update / config patch / standing order", %{conn: conn} do
      ws =
        workspace(%{
          worker_env: %{
            "API_TOKEN" => %{"value" => @secret_value, "secret" => true},
            "LOG_LEVEL" => %{"value" => @plain_value, "secret" => false}
          },
          secrets: %{"gh" => @secret_value <> "-secret-store"}
        })

      responses = [
        conn |> get(~p"/api/workspaces/#{ws.id}") |> response(200),
        conn |> get(~p"/api/workspaces") |> response(200),
        conn
        |> patch(~p"/api/workspaces/#{ws.id}", %{worker_env: %{"MORE" => %{"value" => @secret_value}}})
        |> response(200),
        conn
        |> patch(~p"/api/workspaces/#{ws.id}/config", %{patch: %{"merge" => %{"auto_merge" => true}}})
        |> response(200),
        conn
        |> post(~p"/api/workspaces/#{ws.id}/standing_orders", %{text: "an order"})
        |> response(200),
        conn
        |> post(~p"/api/workspaces", %{
          name: "p21-create-redact",
          worker_env: %{"Z" => %{"value" => @secret_value, "secret" => true}},
          secrets: %{"k" => @secret_value}
        })
        |> response(201)
      ]

      for body <- responses do
        refute body =~ @secret_value
        refute body =~ "SUPERSECRET"
      end

      # The plain-flagged value is still a value: names + flags only.
      for body <- responses, do: refute(body =~ @plain_value)
    end

    test "MCP workspace_show and workspace_config_get", %{conn: _conn} do
      ws =
        workspace(%{
          worker_env: %{"API_TOKEN" => %{"value" => @secret_value, "secret" => true}},
          secrets: %{"gh" => @secret_value}
        })

      scope = %Scope{tier: :coordinator, workspace_id: ws.id}

      for tool <- [&Tools.workspace_show/2, &Tools.workspace_config_get/2, &Tools.workspace_config_overview/2] do
        assert {:ok, data} = tool.(scope, %{})
        refute inspect(data) =~ @secret_value
        refute Jason.encode!(data) =~ @secret_value
      end

      assert {:ok, data} = Tools.workspace_show(scope, %{})
      assert data.worker_env == [%{name: "API_TOKEN", secret: true}]
      assert data.secret_keys == ["gh"]
    end
  end

  describe "GET /api/workspaces/config_schema" do
    test "returns the reference text and the enums", %{conn: conn} do
      body = conn |> get(~p"/api/workspaces/config_schema") |> json_response(200)

      assert body["text"] =~ "WORKSPACE CONFIG REFERENCE"
      assert body["enums"]["tracker_types"] == Workspace.valid_tracker_types()
    end
  end

  describe "standing orders over REST" do
    test "add, remove by index and text, repo-scoped", %{conn: conn} do
      ws = workspace(%{config: %{"repo_paths" => %{"r1" => "/tmp/r1"}}})

      body = conn |> post(~p"/api/workspaces/#{ws.id}/standing_orders", %{text: "one"}) |> json_response(200)
      assert body["standing_orders"] == ["one"]

      body = conn |> post(~p"/api/workspaces/#{ws.id}/standing_orders", %{text: "two"}) |> json_response(200)
      assert body["standing_orders"] == ["one", "two"]

      body =
        conn
        |> post(~p"/api/workspaces/#{ws.id}/standing_orders", %{text: "repo one", repo: "r1"})
        |> json_response(200)

      assert body["standing_orders"] == ["repo one"]
      assert body["repo"] == "r1"

      body =
        conn
        |> post(~p"/api/workspaces/#{ws.id}/standing_orders/remove", %{target: 1})
        |> json_response(200)

      assert body["standing_orders"] == ["two"]

      body =
        conn
        |> post(~p"/api/workspaces/#{ws.id}/standing_orders/remove", %{target: "two"})
        |> json_response(200)

      assert body["standing_orders"] == []

      {:ok, fresh} = Ash.get(Workspace, ws.id)
      assert fresh.config["repo_paths"]["r1"]["standing_orders"] == ["repo one"]
    end

    test "errors: blank text 422, unknown target 404, unregistered repo 404", %{conn: conn} do
      ws = workspace()

      assert conn |> post(~p"/api/workspaces/#{ws.id}/standing_orders", %{text: " "}) |> json_response(422)

      assert conn
             |> post(~p"/api/workspaces/#{ws.id}/standing_orders/remove", %{target: "nope"})
             |> json_response(404)

      assert conn
             |> post(~p"/api/workspaces/#{ws.id}/standing_orders", %{text: "x", repo: "ghost"})
             |> json_response(404)
    end

    test "concurrent adds both survive", %{conn: conn} do
      ws = workspace()
      texts = for n <- 1..8, do: "concurrent #{n}"

      statuses =
        texts
        |> Enum.map(fn text ->
          Task.async(fn ->
            conn |> post(~p"/api/workspaces/#{ws.id}/standing_orders", %{text: text}) |> Map.fetch!(:status)
          end)
        end)
        |> Task.await_many(15_000)

      assert Enum.all?(statuses, &(&1 == 200))
      {:ok, fresh} = Ash.get(Workspace, ws.id)
      assert Enum.sort(fresh.config["standing_orders"]) == Enum.sort(texts)
    end
  end
end
