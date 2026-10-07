defmodule ArbiterCli.Cmd.MessageTest do
  use ArbiterCli.CliCase, async: false

  setup do
    prev = System.get_env("ARB_WORKSPACE")
    System.delete_env("ARB_WORKSPACE")

    on_exit(fn ->
      if prev,
        do: System.put_env("ARB_WORKSPACE", prev),
        else: System.delete_env("ARB_WORKSPACE")
    end)

    :ok
  end

  @workspaces %{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}

  describe "arb message <task-id> <text>" do
    test "sends a direction to the task" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces, 200}},
        {{"post", "/api/messages"},
         fn conn ->
           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{"id" => "m-1", "kind" => "direction"})
         end}
      ])

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Message.run(["bd-xyz", "check", "the", "API"]) end)

      assert code == 0
      assert out =~ "Direction sent to bd-xyz."
    end

    test "requires text after the task id" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Message.run(["bd-xyz"]) end)
      assert code != 0
      assert err =~ "message requires text"
    end

    test "requires a task id" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Message.run([]) end)
      assert code != 0
      assert err =~ "message requires"
    end

    test "--json emits the created message" do
      stub_routes([
        {{"get", "/api/workspaces"}, {@workspaces, 200}},
        {{"post", "/api/messages"},
         fn conn ->
           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{"id" => "m-1", "kind" => "direction"})
         end}
      ])

      {out, err, code} =
        capture(fn -> ArbiterCli.Cmd.Message.run(["bd-xyz", "do", "the", "thing", "--json"]) end)

      assert code == 0,
             "Failed with exit code #{code}, err: #{inspect(err)}, out: #{inspect(out)}"

      assert {:ok, %{"id" => "m-1"}} = Jason.decode(out)
    end
  end

  describe "recipient task workspace inference (D-M-1)" do
    test "message send files under recipient task workspace rather than CLI default" do
      test_pid = self()

      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-default", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"get", "/api/issues/bd-other"},
         {%{"data" => %{"id" => "bd-other", "workspace_id" => "ws-recipient"}}, 200}},
        {{"post", "/api/messages"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(test_pid, {:message_body, Jason.decode!(body)})

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{"id" => "m-2", "kind" => "info"})
         end}
      ])

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Message.run(["send", "bd-other", "hello from cli"]) end)

      assert code == 0
      assert out =~ "Sent info to bd-other."
      assert_received {:message_body, payload}
      assert payload["workspace_id"] == "ws-recipient"
      assert payload["to_ref"] == "bd-other"
      assert payload["body"] == "hello from cli"
    end

    test "direction shorthand files under recipient task workspace rather than CLI default" do
      test_pid = self()

      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-default", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"get", "/api/issues/bd-other"},
         {%{"data" => %{"id" => "bd-other", "workspace_id" => "ws-recipient"}}, 200}},
        {{"post", "/api/messages"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(test_pid, {:direction_body, Jason.decode!(body)})

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{"id" => "m-3", "kind" => "direction"})
         end}
      ])

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Message.run(["bd-other", "please re-check"]) end)

      assert code == 0
      assert out =~ "Direction sent to bd-other."
      assert_received {:direction_body, payload}
      assert payload["workspace_id"] == "ws-recipient"
      assert payload["to_ref"] == "bd-other"
    end

    test "message send with -w overrides CLI default workspace when recipient is not a task" do
      test_pid = self()

      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-custom", "name" => "custom", "prefix" => "cx"}]}, 200}},
        {{"get", "/api/issues/coordinator"}, {%{"error" => "not found"}, 404}},
        {{"post", "/api/messages"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(test_pid, {:message_body, Jason.decode!(body)})

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{"id" => "m-4", "kind" => "info"})
         end}
      ])

      {out, _err, code} =
        capture(fn ->
          ArbiterCli.Main.main(["message", "send", "coordinator", "ping", "-w", "custom"])
        end)

      assert code == 0
      assert out =~ "Sent info to coordinator."
      assert_received {:message_body, payload}
      assert payload["workspace_id"] == "ws-custom"
    end
  end
end
