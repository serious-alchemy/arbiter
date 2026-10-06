defmodule ArbiterCli.ArgParserTest do
  use ExUnit.Case, async: true

  alias ArbiterCli.ArgParser

  defp die_with(argv, opts), do: die_with_fun(fn -> ArgParser.parse(argv, opts) end)

  defp die_with_fun(fun) do
    Process.put(:bd2_halt_strategy, :raise)

    {result, err} =
      ExUnit.CaptureIO.with_io(:stderr, fn ->
        try do
          fun.()
        rescue
          e in ArbiterCli.Output.Halt -> {:halt, e.code}
        end
      end)

    case result do
      {:halt, code} -> {:error, err, code}
      other -> {:ok, other}
    end
  end

  describe "parse/2" do
    test "splits flags from positionals and defaults mode to :text" do
      {opts, rest, mode} =
        ArgParser.parse(["foo", "--reason", "because"], switches: [reason: :string])

      assert opts[:reason] == "because"
      assert rest == ["foo"]
      assert mode == :text
    end

    test "detects --json and reports :json mode without needing it declared explicitly" do
      {opts, rest, mode} = ArgParser.parse(["--json", "foo"], switches: [reason: :string])

      assert opts[:json] == true
      assert rest == ["foo"]
      assert mode == :json
    end

    test "passes through aliases" do
      {opts, _rest, _mode} =
        ArgParser.parse(["-r", "because"], switches: [reason: :string], aliases: [r: :reason])

      assert opts[:reason] == "because"
    end

    test "honors an explicit :strict switches list for declared flags" do
      {opts, rest, _mode} =
        ArgParser.parse(["foo", "--reason", "because"], strict: [reason: :string, json: :boolean])

      assert opts[:reason] == "because"
      assert rest == ["foo"]
    end

    test "dies on an unknown flag, naming the flag and the command" do
      assert {:error, err, 1} = die_with(["foo", "--bogus"], command: "arb widget", switches: [])
      assert err =~ "unknown option --bogus for arb widget"
    end

    test "an unknown flag is rejected even when a value follows it" do
      assert {:error, err, 1} =
               die_with(["--bogus", "value"], command: "arb widget", switches: [reason: :string])

      assert err =~ "unknown option --bogus for arb widget"
    end

    test "dies when a typed flag's value does not parse" do
      assert {:error, err, 1} =
               die_with(["--priority", "abc"],
                 command: "arb widget",
                 switches: [priority: :integer]
               )

      assert err =~ "invalid value \"abc\" for --priority"
      assert err =~ "expected an integer"
    end

    test "dies when a value flag has no value" do
      assert {:error, err, 1} =
               die_with(["--reason"], command: "arb widget", switches: [reason: :string])

      assert err =~ "--reason"
      assert err =~ "requires a value"
    end

    test "accepts --json and --help/-h without declaring them" do
      {opts, _rest, mode} = ArgParser.parse(["--json", "-h"], command: "arb widget", switches: [])

      assert opts[:help] == true
      assert mode == :json
    end

    test "passthrough: true is the explicit opt-out and keeps unknown flags" do
      {opts, rest, _mode} =
        ArgParser.parse(["foo", "--bogus", "--priority", "abc"],
          passthrough: true,
          switches: [priority: :integer]
        )

      assert opts[:bogus] == true
      assert rest == ["foo"]
    end
  end

  describe "difficulty!/1" do
    test "accepts 0..5 with or without the D prefix" do
      for n <- 0..5 do
        assert ArgParser.difficulty!("#{n}") == n
        assert ArgParser.difficulty!("D#{n}") == n
        assert ArgParser.difficulty!("d#{n}") == n
      end
    end

    test "passes nil through" do
      assert ArgParser.difficulty!(nil) == nil
    end

    test "dies on anything else" do
      for bad <- ["6", "D6", "-1", "abc", "D", "3x", ""] do
        assert {:error, err, 1} = die_with_fun(fn -> ArgParser.difficulty!(bad) end)
        assert err =~ "invalid --difficulty"
      end
    end
  end

  describe "coerce_difficulty/1" do
    test "rewrites a parsed string into the integer, leaving other keys alone" do
      assert ArgParser.coerce_difficulty(difficulty: "D3", json: true) == [
               difficulty: 3,
               json: true
             ]

      assert ArgParser.coerce_difficulty(json: true) == [json: true]
    end
  end

  describe "parse_strict!/3" do
    test "dies via Output.die/1 on an unknown flag" do
      assert {:error, err, 1} =
               die_with_fun(fn ->
                 ArgParser.parse_strict!(["--bogus"], "arb test", strict: [reason: :string])
               end)

      assert err =~ "unknown option --bogus for arb test"
    end

    test "passes the hint to Output.die/2" do
      assert {:error, err, 1} =
               die_with_fun(fn ->
                 ArgParser.parse_strict!(["--bogus"], "arb test",
                   strict: [],
                   hint: fn flag -> "try #{flag} elsewhere" end
                 )
               end)

      assert err =~ "hint: try --bogus elsewhere"
    end
  end

  describe "unless_help/3" do
    test "runs the function when --help/-h is absent" do
      assert ArgParser.unless_help(["foo"], "usage text", fn -> :ran end) == :ran
    end

    test "prints usage and does not run the function when --help is present" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          refute ArgParser.unless_help(["--help"], "usage text", fn -> flunk("should not run") end) ==
                   :ran
        end)

      assert output =~ "usage text"
    end

    test "prints usage and does not run the function when -h is present" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          ArgParser.unless_help(["-h"], "usage text", fn -> flunk("should not run") end)
        end)

      assert output =~ "usage text"
    end
  end
end
