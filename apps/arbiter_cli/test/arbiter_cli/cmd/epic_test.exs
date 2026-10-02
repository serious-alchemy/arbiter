defmodule ArbiterCli.Cmd.EpicTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Epic

  @epic %{
    "id" => "bd-ep1",
    "title" => "An epic",
    "issue_type" => "epic",
    "state" => "backlog",
    "priority" => 3,
    "floor_priority" => 1
  }

  defp stub_floor(expected_body, response \\ @epic, status \\ 200) do
    stub_routes([
      {{"patch", "/api/issues/bd-ep1/floor"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         assert Jason.decode!(body) == expected_body
         conn |> Plug.Conn.put_status(status) |> Req.Test.json(response)
       end}
    ])
  end

  describe "arb epic floor <id> <floor>" do
    test "P1 sends floor_priority 1 and reports it" do
      stub_floor(%{"floor_priority" => 1})

      {out, _err, exit_code} = capture(fn -> Epic.run(["floor", "bd-ep1", "P1"]) end)

      assert exit_code == 0
      assert out =~ "bd-ep1"
      assert out =~ "floor P1"
      assert out =~ "epic priority (display only) P3"
    end

    test "accepts p2 and a bare 3" do
      stub_floor(%{"floor_priority" => 2}, %{@epic | "floor_priority" => 2})
      {_out, _err, 0} = capture(fn -> Epic.run(["floor", "bd-ep1", "p2"]) end)

      stub_floor(%{"floor_priority" => 3}, %{@epic | "floor_priority" => 3})
      {_out, _err, 0} = capture(fn -> Epic.run(["floor", "bd-ep1", "3"]) end)
    end

    test "none clears the floor (sends null)" do
      stub_floor(%{"floor_priority" => nil}, %{@epic | "floor_priority" => nil})

      {out, _err, exit_code} = capture(fn -> Epic.run(["floor", "bd-ep1", "none"]) end)

      assert exit_code == 0
      assert out =~ "floor none"
    end

    test "--json emits the updated ticket" do
      stub_floor(%{"floor_priority" => 1})

      {out, _err, exit_code} = capture(fn -> Epic.run(["floor", "bd-ep1", "P1", "--json"]) end)

      assert exit_code == 0
      assert {:ok, %{"id" => "bd-ep1", "floor_priority" => 1}} = Jason.decode(out)
    end

    test "P0 and P4 are refused client-side, before any request" do
      for bad <- ["P0", "0", "P4", "banana"] do
        {_out, err, exit_code} = capture(fn -> Epic.run(["floor", "bd-ep1", bad]) end)
        assert exit_code == 1
        assert err =~ "P1, P2, P3 or none"
      end
    end

    test "requires an id and a floor" do
      {_out, err, exit_code} = capture(fn -> Epic.run(["floor"]) end)
      assert exit_code == 1
      assert err =~ "epic floor requires"

      {_out, err, exit_code} = capture(fn -> Epic.run(["floor", "bd-ep1"]) end)
      assert exit_code == 1
      assert err =~ "epic floor requires"
    end

    test "surfaces the server's refusal (non-epic, worker token)" do
      stub_floor(
        %{"floor_priority" => 1},
        %{
          "error" => %{
            "type" => "validation_error",
            "message" => "only an epic can carry a priority floor"
          }
        },
        422
      )

      {_out, err, exit_code} = capture(fn -> Epic.run(["floor", "bd-ep1", "P1"]) end)
      assert exit_code == 1
      assert err =~ "only an epic"
    end
  end

  test "unknown or missing subcommand" do
    {_out, err, exit_code} = capture(fn -> Epic.run(["nope"]) end)
    assert exit_code == 1
    assert err =~ "unknown epic subcommand"

    {_out, err, exit_code} = capture(fn -> Epic.run([]) end)
    assert exit_code == 1
    assert err =~ "epic requires a subcommand"
  end

  test "is a known top-level resource" do
    assert "epic" in ArbiterCli.AliasResolver.known_verbs()
  end
end
