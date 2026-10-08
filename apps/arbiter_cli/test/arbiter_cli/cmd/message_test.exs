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

  describe "workspace is the server's call (D-M-1)" do
    defp capture_post(test_pid, tag, kind) do
      fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {tag, Jason.decode!(body)})
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => "m", "kind" => kind})
      end
    end

    test "message send names no workspace, so the server files it under the recipient's" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-default", "name" => "default", "prefix" => "bd"}]}, 200}},
        {{"post", "/api/messages"}, capture_post(self(), :message_body, "info")}
      ])

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Message.run(["send", "bd-other", "hello from cli"]) end)

      assert code == 0
      assert out =~ "Sent info to bd-other."
      assert_received {:message_body, payload}
      refute Map.has_key?(payload, "workspace_id")
      refute Map.has_key?(payload, "workspace")
      assert payload["to_ref"] == "bd-other"
      assert payload["body"] == "hello from cli"
    end

    test "direction shorthand names no workspace either" do
      stub_routes([
        {{"post", "/api/messages"}, capture_post(self(), :direction_body, "direction")}
      ])

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Message.run(["bd-other", "please re-check"]) end)

      assert code == 0
      assert out =~ "Direction sent to bd-other."
      assert_received {:direction_body, payload}
      refute Map.has_key?(payload, "workspace_id")
      assert payload["to_ref"] == "bd-other"
    end

    test "-w is forwarded as a claim the server validates against the recipient" do
      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-custom", "name" => "custom", "prefix" => "cx"}]}, 200}},
        {{"post", "/api/messages"}, capture_post(self(), :message_body, "info")}
      ])

      {out, _err, code} =
        capture(fn ->
          ArbiterCli.Main.main(["message", "send", "coordinator", "ping", "-w", "custom"])
        end)

      assert code == 0
      assert out =~ "Sent info to coordinator."
      assert_received {:message_body, payload}
      assert payload["workspace"] == "ws-custom"
    end
  end

  describe "verb-less typo (D-M-9)" do
    test "a typo'd verb is surfaced as the server's not-found, not a sent message" do
      stub_routes([
        {{"post", "/api/messages"},
         {%{"error" => %{"type" => "not_found", "message" => "task sned not found"}}, 404}}
      ])

      {out, err, code} =
        capture(fn -> ArbiterCli.Cmd.Message.run(["sned", "bd-1", "hi"]) end)

      assert code != 0
      refute out =~ "sent"
      assert err =~ "task sned not found"
    end

    test "an empty body (only --json) is refused before anything is posted" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Message.run(["bd-1", "--json"]) end)
      assert code != 0
      assert err =~ "message requires text"
    end
  end

  describe "--directive" do
    test "warns that it is deprecated" do
      stub_routes([
        {{"post", "/api/messages"},
         fn conn ->
           conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => "m", "kind" => "info"})
         end}
      ])

      {_out, err, code} =
        capture(fn ->
          ArbiterCli.Cmd.Message.run(["send", "bd-x", "hi", "--directive", "bd-y"])
        end)

      assert code == 0
      assert err =~ "--directive` is deprecated"
    end
  end
end
