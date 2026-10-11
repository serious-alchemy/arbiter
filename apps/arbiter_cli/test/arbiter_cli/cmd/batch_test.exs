defmodule ArbiterCli.Cmd.BatchTest do
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Batch

  defp run_batch(argv, input) do
    {out, err, code} = capture(fn -> Batch.run(argv) end, input: input)
    lines = out |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    {lines, err, code}
  end

  defp stub_ticket_world do
    stub_routes([
      {{"get", "/api/issues/bd-1"}, {%{"id" => "bd-1", "title" => "One"}, 200}},
      {{"get", "/api/issues/bd-2"}, {%{"error" => "nope"}, 404}},
      {{"get", "/api/issues/bd-3"}, {%{"id" => "bd-3", "title" => "Three"}, 200}}
    ])
  end

  describe "split_line/1" do
    test "shell-like quoting, comments and optional arb prefix" do
      assert Batch.split_line(~s(arb ticket show "bd 1" 'a b' c\\ d)) ==
               {:ok, ["ticket", "show", "bd 1", "a b", "c d"]}

      assert Batch.split_line("  # a comment") == :skip
      assert Batch.split_line("") == :skip
      assert Batch.split_line("ticket show bd-1 # trailing") == {:ok, ["ticket", "show", "bd-1"]}
      assert Batch.split_line(~s(ticket show "#notcomment)) == {:error, "unterminated quote"}
    end
  end

  describe "refusal" do
    test "interactive, long-lived and nested lines are refused with a clear error" do
      input = """
      batch
      watch
      server restart
      server deploy
      restart
      worker log bd-1 -f
      worker log bd-1 --follow
      """

      {lines, _err, code} = run_batch(["--continue-on-error"], input)
      assert code == 1
      assert length(lines) == 7
      assert Enum.all?(lines, &(&1["exit"] == 1))
      assert Enum.at(lines, 0)["error"] =~ "nested"
      assert Enum.all?(Enum.drop(lines, 1), &(&1["error"] =~ "not allowed in arb batch"))
    end
  end

  describe "execution" do
    test "mixed lines run in one VM and emit one JSON result per line" do
      stub_ticket_world()

      input = """
      # a comment
      ticket show bd-1

      ticket show bd-3
      """

      {lines, _err, code} = run_batch([], input)
      assert code == 0
      assert [first, second] = lines
      assert first["line"] == 2
      assert first["argv"] == ["ticket", "show", "bd-1"]
      assert first["exit"] == 0
      assert first["output"]["id"] == "bd-1"
      assert second["line"] == 4
      assert second["output"]["id"] == "bd-3"
    end

    test "a batch mixing read and write commands runs them in order" do
      stub_routes([
        {{"get", "/api/issues/bd-1"}, {%{"id" => "bd-1", "title" => "Old"}, 200}},
        {{"patch", "/api/issues/bd-1"}, {%{"id" => "bd-1", "title" => "New"}, 200}}
      ])

      input = "ticket show bd-1\nticket update bd-1 --title New\nticket show bd-1\n"
      {lines, _err, code} = run_batch([], input)
      assert code == 0

      assert [%{"exit" => 0}, %{"exit" => 0, "output" => %{"title" => "New"}}, %{"exit" => 0}] =
               lines
    end

    test "write commands go through too" do
      stub_routes([
        {{"patch", "/api/issues/bd-1"}, {%{"id" => "bd-1", "title" => "New"}, 200}}
      ])

      {lines, _err, code} = run_batch([], "ticket update bd-1 --title New\n")
      assert code == 0
      assert [%{"exit" => 0, "output" => %{"title" => "New"}}] = lines
    end

    test "stops at the first failure by default" do
      stub_ticket_world()

      {lines, _err, code} =
        run_batch([], "ticket show bd-1\nticket show bd-2\nticket show bd-3\n")

      assert code != 0
      assert [%{"exit" => 0}, %{"exit" => e, "error" => err}] = lines
      assert e != 0
      assert is_binary(err)
    end

    test "--continue-on-error keeps going and still exits non-zero" do
      stub_ticket_world()

      {lines, _err, code} =
        run_batch(
          ["--continue-on-error"],
          "ticket show bd-1\nticket show bd-2\nticket show bd-3\n"
        )

      assert code != 0
      assert [%{"exit" => 0}, %{"exit" => e}, %{"exit" => 0}] = lines
      assert e != 0
    end

    test "--file reads commands from a file" do
      stub_ticket_world()
      path = Path.join(System.tmp_dir!(), "batch-#{System.unique_integer([:positive])}.txt")
      File.write!(path, "ticket show bd-1\n")
      on_exit(fn -> File.rm(path) end)

      {lines, _err, code} = run_batch(["--file", path], "")
      assert code == 0
      assert [%{"exit" => 0, "output" => %{"id" => "bd-1"}}] = lines
    end

    test "unknown flag is rejected" do
      {_out, err, code} = capture(fn -> Batch.run(["--bogus-flag"]) end, input: "")
      assert code == 1
      assert err =~ "unknown option --bogus-flag for arb batch"
    end
  end
end
