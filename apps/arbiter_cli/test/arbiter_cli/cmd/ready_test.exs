defmodule ArbiterCli.Cmd.ReadyTest do
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Ready

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

  defp stub_two(ready_data) do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"get", "/api/issues/ready"}, {%{"data" => ready_data}, 200}}
    ])
  end

  test "lists ready issues from the active workspace by default" do
    stub_two([%{"id" => "a", "state" => "queued", "priority" => 1, "title" => "ready one"}])

    {out, _err, exit_code} = capture(fn -> Ready.run([]) end)
    assert exit_code == 0
    assert out =~ "ready one"
  end

  test "empty list prints placeholder" do
    stub_two([])
    {out, _err, _} = capture(fn -> Ready.run([]) end)
    assert out =~ "(no tickets)"
  end

  test "--all skips the workspace filter" do
    stub_two([%{"id" => "all-1", "state" => "queued", "priority" => 1, "title" => "cross-ws"}])

    {out, _err, exit_code} = capture(fn -> Ready.run(["--all"]) end)
    assert exit_code == 0
    assert out =~ "cross-ws"
  end

  test "bad selector -w bogus dies with exit 1 rather than silently widening" do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}}
    ])

    {_out, err, exit_code} =
      capture(fn -> ArbiterCli.Main.main(["ticket", "ready", "-w", "bogus"]) end)

    assert exit_code == 1
    assert err =~ "no workspace named"
  end

  test "-w sends the resolved workspace_id" do
    test_pid = self()

    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-acme", "name" => "acme", "prefix" => "ax"}]}, 200}},
      {{"get", "/api/issues/ready"},
       fn conn ->
         send(test_pid, {:ready_query, conn.query_params})
         conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"data" => []})
       end}
    ])

    {_out, _err, exit_code} =
      capture(fn -> ArbiterCli.Main.main(["ticket", "ready", "-w", "acme"]) end)

    assert exit_code == 0
    assert_received {:ready_query, %{"workspace_id" => "ws-acme"}}
  end
end
