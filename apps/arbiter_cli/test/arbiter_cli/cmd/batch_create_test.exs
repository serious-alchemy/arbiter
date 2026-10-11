defmodule ArbiterCli.Cmd.BatchCreateTest do
  @moduledoc """
  `arb ticket create` batch + inline-edge forms, and `arb dep add --stdin`:
  `--depends-on` / `--blocks`, `--from-file <json|yaml|->` / `--stdin`, `--promote`,
  and the bulk dependency add with per-edge output.
  """
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.{Create, Dep}

  @ws {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}, 200}}

  @batch_ok %{
    "refs" => %{"epic" => "bd-1", "a" => "bd-2"},
    "counts" => %{"tickets" => 2, "edges" => 1},
    "tickets" => [
      %{
        "index" => 0,
        "ref" => "epic",
        "id" => "bd-1",
        "title" => "The epic",
        "state" => "backlog"
      },
      %{
        "index" => 1,
        "ref" => "a",
        "id" => "bd-2",
        "title" => "Step a",
        "state" => "backlog",
        "warnings" => ["No acceptance criteria set."]
      }
    ],
    "edges" => [%{"from_issue_id" => "bd-1", "to_issue_id" => "bd-2", "type" => "parent_of"}]
  }

  defp capture_post(path, reply, status \\ 201) do
    parent = self()

    stub_routes([
      @ws,
      {{"post", path},
       fn conn ->
         {:ok, raw, conn} = Plug.Conn.read_body(conn)
         send(parent, {:posted, path, Jason.decode!(raw)})
         conn |> Plug.Conn.put_status(status) |> Req.Test.json(reply)
       end}
    ])
  end

  defp write_tmp!(name, content) do
    dir = Path.join(System.tmp_dir!(), "arb-batch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  describe "arb ticket create — inline edges" do
    test "--depends-on and --blocks ride along in the one POST" do
      capture_post("/api/issues", %{"id" => "bd-9", "title" => "X", "state" => "backlog"})

      {_out, _err, 0} =
        capture(fn -> Create.run(["X", "--depends-on", "bd-1,bd-2", "--blocks", "bd-3"]) end)

      assert_received {:posted, "/api/issues", body}
      assert body["depends_on"] == ["bd-1", "bd-2"]
      assert body["blocks"] == ["bd-3"]
    end

    test "--deps keeps its own key (the server treats it as depends_on)" do
      capture_post("/api/issues", %{"id" => "bd-9", "title" => "X", "state" => "backlog"})
      {_out, _err, 0} = capture(fn -> Create.run(["X", "--deps", "bd-1"]) end)
      assert_received {:posted, "/api/issues", body}
      assert body["deps"] == ["bd-1"]
    end
  end

  describe "arb ticket create --from-file" do
    @json ~s({"tickets": [
      {"ref": "epic", "title": "The epic", "issue_type": "epic"},
      {"ref": "a", "title": "Step a", "parent_id": "epic", "depends_on": ["bd-77"]}
    ]})

    test "a JSON file is posted to the batch endpoint and the ref -> id map is printed" do
      capture_post("/api/issues/batch", @batch_ok)
      path = write_tmp!("batch.json", @json)

      {out, err, exit_code} = capture(fn -> Create.run(["--from-file", path]) end)

      assert exit_code == 0
      assert_received {:posted, "/api/issues/batch", body}
      assert body["workspace_id"] == "ws-1"
      assert [%{"ref" => "epic"}, %{"ref" => "a", "depends_on" => ["bd-77"]}] = body["tickets"]
      refute Map.has_key?(body, "promote")

      assert out =~ "epic -> bd-1"
      assert out =~ "a -> bd-2"
      assert out =~ "2 tickets"
      assert err =~ "No acceptance criteria"
    end

    test "a YAML file works, and a bare top-level list is the tickets" do
      capture_post("/api/issues/batch", @batch_ok)

      path =
        write_tmp!("batch.yaml", """
        - ref: epic
          title: The epic
          issue_type: epic
        - ref: a
          title: Step a
          parent_id: epic
          depends_on: [bd-77]
        """)

      {_out, _err, 0} = capture(fn -> Create.run(["--from-file", path]) end)

      assert_received {:posted, "/api/issues/batch", body}
      assert [%{"title" => "The epic"}, %{"depends_on" => ["bd-77"]}] = body["tickets"]
    end

    test "--from-file - and --stdin read the document from stdin" do
      capture_post("/api/issues/batch", @batch_ok)

      {_out, _err, 0} = capture(fn -> Create.run(~w(--from-file -)) end, input: @json)
      assert_received {:posted, "/api/issues/batch", %{"tickets" => [_, _]}}

      {_out, _err, 0} = capture(fn -> Create.run(~w(--stdin)) end, input: @json)
      assert_received {:posted, "/api/issues/batch", %{"tickets" => [_, _]}}
    end

    test "--promote and --force are sent; so are document-level promote/force" do
      capture_post(
        "/api/issues/batch",
        Map.put(@batch_ok, "promote", %{
          "counts" => %{"total" => 2, "ok" => 2},
          "results" => [
            %{
              "id" => "bd-1",
              "status" => "ok",
              "ticket" => %{"id" => "bd-1", "state" => "queued"}
            },
            %{
              "id" => "bd-2",
              "status" => "ok",
              "ticket" => %{"id" => "bd-2", "state" => "queued"}
            }
          ]
        })
      )

      path = write_tmp!("batch.json", @json)

      {out, _err, 0} =
        capture(fn -> Create.run(["--from-file", path, "--promote", "--force"]) end)

      assert_received {:posted, _, %{"promote" => true, "force" => true}}
      assert out =~ "promoted"
      assert out =~ "bd-1"

      doc = write_tmp!("doc.json", ~s({"promote": true, "tickets": [{"title": "x"}]}))
      {_out, _err, 0} = capture(fn -> Create.run(["--from-file", doc]) end)
      assert_received {:posted, _, %{"promote" => true}}
    end

    test "--json prints the server response untouched" do
      capture_post("/api/issues/batch", @batch_ok)
      path = write_tmp!("batch.json", @json)

      {out, _err, 0} = capture(fn -> Create.run(["--from-file", path, "--json"]) end)
      assert {:ok, %{"refs" => %{"epic" => "bd-1"}}} = Jason.decode(out)
    end

    test "a refused batch exits non-zero with the server's entry-naming message" do
      stub_routes([
        @ws,
        {{"post", "/api/issues/batch"},
         {%{
            "error" => %{
              "type" => "not_found",
              "message" =>
                "tickets[1] \"Step a\": ghost is neither a ref in this batch nor an existing ticket",
              "details" => %{"index" => 1}
            }
          }, 404}}
      ])

      path = write_tmp!("batch.json", @json)
      {_out, err, exit_code} = capture(fn -> Create.run(["--from-file", path]) end)

      assert exit_code != 0
      assert err =~ "tickets[1]"
    end

    test "an unreadable or malformed file posts nothing" do
      capture_post("/api/issues/batch", @batch_ok)

      {_out, err, exit_code} =
        capture(fn -> Create.run(["--from-file", "/nonexistent/batch.json"]) end)

      assert exit_code != 0
      assert err =~ "/nonexistent/batch.json"

      bad = write_tmp!("bad.json", "{not valid")
      {_out, err, exit_code} = capture(fn -> Create.run(["--from-file", bad]) end)
      assert exit_code != 0
      assert err =~ "bad.json" or err =~ "parse"

      empty = write_tmp!("empty.json", "[]")
      {_out, _err, exit_code} = capture(fn -> Create.run(["--from-file", empty]) end)
      assert exit_code != 0

      refute_received {:posted, _, _}
    end

    test "a title argument alongside --from-file is refused" do
      path = write_tmp!("batch.json", @json)
      {_out, err, exit_code} = capture(fn -> Create.run(["Some title", "--from-file", path]) end)
      assert exit_code != 0
      assert err =~ "--from-file"
    end
  end

  describe "arb dep add --stdin" do
    @mixed %{
      "results" => [
        %{"index" => 0, "from" => "bd-1", "to" => "bd-2", "type" => "blocks", "status" => "ok"},
        %{
          "index" => 1,
          "from" => "bd-2",
          "to" => "bd-1",
          "type" => "blocks",
          "status" => "rejected",
          "code" => "cyclic",
          "reason" => "blocks bd-2 → bd-1 would create a dependency cycle"
        }
      ],
      "counts" => %{"total" => 2, "ok" => 1, "rejected" => 1}
    }

    test "a JSON array of edges is posted as `edges`; per-edge lines, exit 1 on a rejection" do
      capture_post("/api/dependencies", @mixed, 200)

      input =
        ~s([{"from": "bd-1", "to": "bd-2", "type": "blocks"}, {"from": "bd-2", "to": "bd-1", "type": "blocks"}])

      {out, _err, exit_code} = capture(fn -> Dep.run(~w(add --stdin)) end, input: input)

      assert exit_code == 1
      assert_received {:posted, "/api/dependencies", %{"edges" => [%{"from" => "bd-1"}, _]}}
      assert out =~ "ok         bd-1 -blocks-> bd-2"
      assert out =~ "rejected   bd-2 -blocks-> bd-1: blocks bd-2"
      assert out =~ "1 ok, 1 rejected (2 total)"
    end

    test "plain `<from> <type> <to>` lines (the positional order of `dep add`) work too" do
      capture_post(
        "/api/dependencies",
        Map.put(@mixed, "counts", %{"total" => 2, "ok" => 2, "rejected" => 0})
        |> Map.update!("results", fn [a, b] -> [a, %{b | "status" => "ok"}] end),
        200
      )

      input = "bd-1 blocks bd-2\n\n# a comment\nbd-3 parent_of bd-4\n"
      {_out, _err, exit_code} = capture(fn -> Dep.run(~w(add --stdin)) end, input: input)

      assert exit_code == 0

      assert_received {:posted, "/api/dependencies",
                       %{
                         "edges" => [
                           %{"from" => "bd-1", "type" => "blocks", "to" => "bd-2"},
                           %{"from" => "bd-3", "type" => "parent_of", "to" => "bd-4"}
                         ]
                       }}
    end

    test "--json prints the response; a malformed line posts nothing" do
      capture_post("/api/dependencies", @mixed, 200)

      {out, _err, 1} =
        capture(fn -> Dep.run(~w(add --stdin --json)) end,
          input: ~s([{"from": "bd-1", "to": "bd-2", "type": "blocks"}])
        )

      assert {:ok, %{"counts" => %{"total" => 2}}} = Jason.decode(out)

      {_out, err, exit_code} =
        capture(fn -> Dep.run(~w(add --stdin)) end, input: "bd-1 blocks\n")

      assert exit_code != 0
      assert err =~ "line 1"
    end

    test "an empty stdin is refused" do
      {_out, _err, exit_code} = capture(fn -> Dep.run(~w(add --stdin)) end, input: "\n")
      assert exit_code != 0
    end

    test "the single positional form is unchanged" do
      capture_post("/api/dependencies", %{
        "id" => "dep-1",
        "from_issue_id" => "bd-1",
        "to_issue_id" => "bd-2",
        "type" => "blocks"
      })

      {_out, _err, 0} = capture(fn -> Dep.run(~w(add bd-1 blocks bd-2)) end)
      assert_received {:posted, "/api/dependencies", %{"from_issue_id" => "bd-1"}}
    end
  end
end
