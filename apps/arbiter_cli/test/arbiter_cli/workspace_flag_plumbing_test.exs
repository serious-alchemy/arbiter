defmodule ArbiterCli.WorkspaceFlagPlumbingTest do
  @moduledoc """
  P-05: `-w <name>` reaches the wire as the resolved workspace id on every
  workspace-aware verb. Each test drives `Main.main/1` (so the flag goes through
  the real central stripping) against a recording stub and asserts the request
  carries `ws-acme`, never the raw name.
  """
  # async: false — `Main.main/1` seeds the process-global ARB_WORKSPACE.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Main

  @workspace %{"id" => "ws-acme", "name" => "acme", "prefix" => "ax"}

  setup do
    saved =
      for k <- ~w(ARB_WORKSPACE ARB_TOKEN ARB_HOST ARB_SESSION_ID), do: {k, System.get_env(k)}

    Enum.each(saved, fn {k, _} -> System.delete_env(k) end)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    test_pid = self()

    Req.Test.stub(Process.get(:bd2_stub_name), fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = if raw == "", do: %{}, else: Jason.decode!(raw)
      send(test_pid, {:request, conn.method, conn.request_path, conn.query_params, body})

      conn |> Plug.Conn.put_status(200) |> Req.Test.json(respond(conn.request_path))
    end)

    :ok
  end

  defp respond("/api/workspaces"), do: %{"data" => [@workspace]}
  defp respond("/api/quota"), do: %{"data" => %{"workspace_id" => "ws-acme", "claude" => nil}}
  defp respond("/api/images/build"), do: %{"data" => %{"tag" => "t"}}

  defp respond("/api/mcp/tokens"),
    do: %{"token" => "T", "tier" => "coordinator", "expires_in" => 1}

  defp respond("/api/usage/calibration"), do: %{"data" => %{}}
  defp respond("/api/nodes/box-1"), do: %{"node" => %{"name" => "box-1"}}
  defp respond(_path), do: %{"data" => []}

  defp run(argv), do: capture(fn -> Main.main(argv) end)

  defp requests_to(path) do
    Stream.repeatedly(fn ->
      receive do
        {:request, method, ^path, query, body} -> {method, query, body}
      after
        0 -> :done
      end
    end)
    |> Enum.take_while(&(&1 != :done))
  end

  defp assert_query(argv, path, key) do
    {_out, err, code} = run(argv)
    assert code == 0, "arb #{Enum.join(argv, " ")} exited #{code}: #{err}"
    assert [{_, query, _} | _] = requests_to(path)
    assert query[key] == "ws-acme", "#{path} query #{inspect(query)} lacks #{key}=ws-acme"
  end

  test "ticket list -w" do
    assert_query(["ticket", "list", "-w", "acme"], "/api/issues", "workspace_id")
  end

  test "usage (summary) -w" do
    assert_query(["usage", "-w", "acme"], "/api/usage", "workspace_id")
  end

  test "usage events -w" do
    assert_query(["usage", "events", "-w", "acme"], "/api/usage/events", "workspace_id")
  end

  test "usage --session -w" do
    assert_query(["usage", "--session", "s-1", "-w", "acme"], "/api/usage/events", "workspace_id")
  end

  test "usage calibration -w" do
    assert_query(
      ["usage", "--calibration", "-w", "acme"],
      "/api/usage/calibration",
      "workspace_id"
    )
  end

  test "quota -w" do
    {_out, err, code} = run(["quota", "-w", "acme"])
    assert code == 0, err
    assert [{_, query, _} | _] = requests_to("/api/quota")
    assert query["workspace"] == "ws-acme"
  end

  test "alert list -w" do
    assert_query(["alert", "list", "-w", "acme"], "/api/alerts", "workspace")
  end

  test "dep list -w" do
    assert_query(["dep", "list", "-w", "acme"], "/api/dependencies", "workspace_id")
  end

  test "message inbox -w" do
    assert_query(["message", "inbox", "-w", "acme"], "/api/messages", "workspace")
  end

  test "message notify -w" do
    assert_query(["message", "notify", "-w", "acme"], "/api/messages", "workspace")
  end

  test "message inbox clear --task -w" do
    test_pid = self()

    Req.Test.stub(Process.get(:bd2_stub_name), fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:request, conn.method, conn.request_path, conn.query_params, %{}})

      body =
        if conn.request_path == "/api/workspaces",
          do: %{"data" => [@workspace]},
          else: %{"data" => %{"cleared" => []}}

      conn |> Plug.Conn.put_status(200) |> Req.Test.json(body)
    end)

    {_out, err, code} = run(["message", "inbox", "clear", "--task", "bd-1", "-w", "acme"])
    assert code == 0, err

    assert [{"DELETE", %{"workspace" => "ws-acme", "task_id" => "bd-1"}, _} | _] =
             requests_to("/api/messages")
  end

  test "message inbox read -w is refused, not dropped" do
    {_out, err, code} = run(["message", "inbox", "read", "bd-1", "-w", "acme"])
    assert code == 1
    assert err =~ "--workspace does not apply to inbox read"
    assert requests_to("/api/messages") == []
  end

  test "ticket ready -w" do
    assert_query(["ticket", "ready", "-w", "acme"], "/api/issues/ready", "workspace_id")
  end

  test "queue -w is rejected, not dropped" do
    {_out, err, code} = run(["queue", "rerun-ci", "bd-1", "-w", "acme"])
    assert code == 1
    assert err =~ "unknown option -w for arb queue"
  end

  test "node set --workspace is the node's own pin switch, not the global selector" do
    {_out, err, code} =
      run(["node", "set", "box-1", "--workspace", "ws-a", "--workspace=ws-b"])

    refute err =~ "unknown option"
    assert code == 0

    assert_received {:request, "PATCH", "/api/nodes/box-1", _,
                     %{"workspace_ids" => ["ws-a", "ws-b"]}}

    {_out, _err, 0} = run(["node", "set", "box-1", "--workspace", "none"])
    assert_received {:request, "PATCH", "/api/nodes/box-1", _, %{"workspace_ids" => []}}
  end

  test "node list -w is still rejected" do
    {_out, err, code} = run(["node", "list", "-w", "acme"])
    assert code == 1
    assert err =~ "unknown option -w for arb node"
  end

  test "worker list -w" do
    assert_query(["worker", "list", "-w", "acme"], "/api/workers", "workspace_id")
  end

  test "worker runs -w" do
    assert_query(["worker", "runs", "bd-1", "-w", "acme"], "/api/workers/history", "workspace_id")
  end

  test "image build -w" do
    {_out, err, code} = run(["image", "build", "somerepo", "-w", "acme"])
    assert code == 0, err
    assert [{"POST", _, %{"workspace" => "ws-acme"}} | _] = requests_to("/api/images/build")
  end

  test "mcp token mint -w" do
    System.put_env("ARB_TOKEN", "caller-token")
    {_out, err, code} = run(["mcp", "token", "mint", "-w", "acme"])
    assert code == 0, err
    assert [{"POST", _, %{"workspace_id" => "ws-acme"}} | _] = requests_to("/api/mcp/tokens")
  end

  test "account attach -w" do
    {_out, _err, _code} = run(["account", "attach", "claude", "acct-1", "-w", "acme"])

    assert [{"POST", _, %{"workspace_id" => "ws-acme", "provider" => "claude"}} | _] =
             requests_to("/api/accounts/acct-1/attach")
  end

  test "prime -w narrows to the selected workspace" do
    {out, err, code} = run(["prime", "-w", "acme", "--json"])
    assert code == 0, err
    assert [%{"workspace" => %{"id" => "ws-acme"}}] = Jason.decode!(out)["workspaces"]
  end

  test "workspace show -w <name> resolves through the workspace list" do
    {_out, err, code} = run(["workspace", "show", "-w", "acme"])
    assert code == 0, err
    assert [{"GET", _, _} | _] = requests_to("/api/workspaces/ws-acme")
  end
end
