defmodule ArbiterCli.Cmd.BulkReadTest do
  @moduledoc "bd-7sxpln: `arb ticket list --with-deps` and `arb ticket show id1 id2 ...`."
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.List
  alias ArbiterCli.Cmd.Show

  test "list --with-deps asks for include=parent,deps and passes the edges through" do
    stub_routes([
      {{"get", "/api/issues"},
       fn conn ->
         assert conn.query_params["include"] == "parent,deps"

         Req.Test.json(conn, %{
           "data" => [%{"id" => "a", "parent_id" => "e", "depends_on" => ["b"], "blocks" => []}]
         })
       end}
    ])

    {out, _err, 0} = capture(fn -> List.run(["--with-deps", "--json"]) end)
    assert {:ok, %{"data" => [%{"parent_id" => "e", "depends_on" => ["b"]}]}} = Jason.decode(out)
  end

  test "list without the flag sends no include" do
    stub_routes([
      {{"get", "/api/issues"},
       fn conn ->
         refute Map.has_key?(conn.query_params, "include")
         Req.Test.json(conn, %{"data" => []})
       end}
    ])

    {_out, _err, 0} = capture(fn -> List.run([]) end)
  end

  test "show with several ids makes one bulk request and reports unknown ids" do
    stub_routes([
      {{"get", "/api/issues"},
       fn conn ->
         assert conn.query_params["ids"] == "a,zz,b"
         assert conn.query_params["include"] == "parent,deps"

         Req.Test.json(conn, %{
           "data" => [
             %{"id" => "a", "title" => "first", "state" => "queued"},
             %{"id" => "b", "title" => "second", "state" => "queued"}
           ],
           "not_found" => ["zz"]
         })
       end}
    ])

    {out, err, 0} = capture(fn -> Show.run(["a", "zz", "b"]) end)
    assert out =~ "first"
    assert out =~ "second"
    assert err =~ "zz"
  end

  test "show with several ids --json emits data and not_found" do
    stub_routes([
      {{"get", "/api/issues"},
       fn conn ->
         Req.Test.json(conn, %{"data" => [%{"id" => "a"}], "not_found" => ["zz"]})
       end}
    ])

    {out, _err, 0} = capture(fn -> Show.run(["a", "zz", "--json"]) end)
    assert {:ok, %{"data" => [%{"id" => "a"}], "not_found" => ["zz"]}} = Jason.decode(out)
  end
end
