defmodule ArbiterCli.PermissionFlagsTest do
  @moduledoc """
  bd-54m4vv (G12): `--permission` / `--remove-permission` on `arb ticket create`
  / `arb ticket update`, and the declared and pending permissions on
  `arb ticket show`.
  """
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.{Create, Update}
  alias ArbiterCli.Output

  @workspace {{"get", "/api/workspaces"},
              {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}}

  defp recording_route(verb, path, reply) do
    test = self()

    {{verb, path},
     fn conn ->
       {:ok, body, conn} = Plug.Conn.read_body(conn)
       send(test, {:sent, Jason.decode!(body)})

       conn
       |> Plug.Conn.put_status(elem(reply, 1))
       |> Req.Test.json(elem(reply, 0))
     end}
  end

  describe "arb ticket create" do
    test "--permission repeats and takes comma lists, sent as permissions" do
      stub_routes([
        @workspace,
        recording_route("post", "/api/issues", {%{"id" => "bd-1", "title" => "T"}, 201})
      ])

      {_out, _err, 0} =
        capture(fn ->
          Create.run([
            "T",
            "--permission",
            "network:api.example.com",
            "--permission",
            "tracker_write,prod_read"
          ])
        end)

      assert_receive {:sent, body}
      assert body["permissions"] == ["network:api.example.com", "tracker_write", "prod_read"]
    end

    test "no flag sends no permissions key" do
      stub_routes([
        @workspace,
        recording_route("post", "/api/issues", {%{"id" => "bd-1", "title" => "T"}, 201})
      ])

      {_out, _err, 0} = capture(fn -> Create.run(["T"]) end)

      assert_receive {:sent, body}
      refute Map.has_key?(body, "permissions")
    end
  end

  describe "arb ticket update" do
    test "--permission adds and --remove-permission removes, server-side" do
      stub_routes([
        recording_route("patch", "/api/issues/bd-1", {%{"id" => "bd-1", "title" => "T"}, 200})
      ])

      {_out, _err, 0} =
        capture(fn ->
          Update.run(["bd-1", "--permission", "prod_read", "--remove-permission", "phi_data"])
        end)

      assert_receive {:sent, body}

      assert body == %{
               "add_permissions" => ["prod_read"],
               "remove_permissions" => ["phi_data"]
             }
    end
  end

  describe "arb ticket show" do
    test "lists the declared permissions and flags the pending ones" do
      text =
        Output.format_issue_detail(%{
          "id" => "bd-1",
          "title" => "T",
          "permissions" => ["prod_ssh", "tracker_write"],
          "pending_permissions" => ["prod_ssh"]
        })

      assert text =~ "Permissions:"
      assert text =~ "tracker_write"
      assert text =~ "prod_ssh (requested"
    end

    test "says nothing when the ticket declares none" do
      refute Output.format_issue_detail(%{"id" => "bd-1", "title" => "T", "permissions" => []}) =~
               "Permissions:"
    end
  end
end
