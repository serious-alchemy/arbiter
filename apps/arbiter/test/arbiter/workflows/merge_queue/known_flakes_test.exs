defmodule Arbiter.Workflows.MergeQueue.KnownFlakesTest do
  # bd-4qj7io: a CI failure confined to registered flaky tests earns one
  # automatic re-run instead of a fix pass.
  use ExUnit.Case, async: true

  alias Arbiter.Workflows.MergeQueue.KnownFlakes

  @entry %{
    id: "demo-flake",
    module: "Demo.FlakyTest",
    test: "sometimes fails",
    ticket: "bd-demo",
    cause: "a race"
  }
  @other %{
    id: "other-flake",
    module: "Demo.OtherTest",
    test: "also flaky",
    ticket: "bd-demo",
    cause: "x"
  }
  @entries [@entry, @other]

  defp check(summary), do: %{name: "mix test", summary: summary}

  defp failure(n, name, module),
    do: "  #{n}) test #{name} (#{module})\n     test/demo_test.exs:#{n}\n     boom\n"

  describe "confined/3" do
    test "is the entry's id when every failure in the log is a registered flaky test" do
      summary =
        failure(1, "describe sometimes fails after a retry", "Demo.FlakyTest") <>
          "\n1 test, 1 failure\n"

      assert KnownFlakes.confined([check(summary)], @entries) == {:ok, ["demo-flake"]}
    end

    test "collects the ids of several registered tests, without duplicates" do
      summary =
        failure(1, "sometimes fails", "Demo.FlakyTest") <>
          failure(2, "sometimes fails again", "Demo.FlakyTest") <>
          failure(3, "also flaky", "Demo.OtherTest") <> "\n9 tests, 3 failures\n"

      assert KnownFlakes.confined([check(summary)], @entries) ==
               {:ok, ["demo-flake", "other-flake"]}
    end

    test "is :none when any failure is an unregistered test" do
      summary =
        failure(1, "sometimes fails", "Demo.FlakyTest") <>
          failure(2, "a real regression", "Demo.FlakyTest") <> "\n9 tests, 2 failures\n"

      assert KnownFlakes.confined([check(summary)], @entries) == :none
    end

    test "a registered test name in another module does not match" do
      summary = failure(1, "sometimes fails", "Demo.ImpostorTest") <> "\n1 test, 1 failure\n"
      assert KnownFlakes.confined([check(summary)], @entries) == :none
    end

    test "is :none when the log lists fewer failures than the run counted (truncated)" do
      summary = failure(1, "sometimes fails", "Demo.FlakyTest") <> "\n9 tests, 3 failures\n"
      assert KnownFlakes.confined([check(summary)], @entries) == :none
    end

    test "sums the failure counts of every app's summary line" do
      summary =
        failure(1, "sometimes fails", "Demo.FlakyTest") <>
          "\n4 tests, 1 failure\n" <> "\n7 tests, 0 failures\n"

      assert KnownFlakes.confined([check(summary)], @entries) == {:ok, ["demo-flake"]}
    end

    test "is :none when a failing check names no test failure (a lint or build failure)" do
      flaky = check(failure(1, "sometimes fails", "Demo.FlakyTest") <> "\n1 test, 1 failure\n")
      lint = check("credo: lib/demo.ex:12 nesting too deep")

      assert KnownFlakes.confined([flaky, lint], @entries) == :none
      assert KnownFlakes.confined([lint], @entries) == :none
    end

    test "is :none with no checks, an empty registry, or no summary text" do
      assert KnownFlakes.confined([], @entries) == :none
      assert KnownFlakes.confined([check("x")], []) == :none
      assert KnownFlakes.confined([%{name: "mix test"}], @entries) == :none
    end
  end

  describe "the registry" do
    test "every entry names its ticket and cause and has a unique id" do
      entries = KnownFlakes.entries()
      assert Enum.any?(entries)
      assert entries |> Enum.map(& &1.id) |> Enum.uniq() |> length() == length(entries)

      for entry <- entries do
        assert is_binary(entry.ticket) and entry.ticket != ""
        assert is_binary(entry.cause) and entry.cause != ""
      end
    end

    test "every entry still matches a test in the repo (a renamed test leaves the registry)" do
      sources =
        Path.expand("../../../../../*/test/**/*_test.exs", __DIR__)
        |> Path.wildcard()
        |> Enum.map(&File.read!/1)

      for %{id: id, test: name} <- KnownFlakes.entries() do
        assert Enum.any?(sources, &String.contains?(&1, name)),
               "registry entry #{id}: no test source contains #{inspect(name)}"
      end
    end

    test "the registered tests of this task are known" do
      ids = Enum.map(KnownFlakes.entries(), & &1.id)

      for id <- ~w(dispatch-queue-quota-preflight-hold remote-checkout-primary-veto
                   ticket-watchdog-direct-strategy worker-resume-rest-mcp-parity) do
        assert id in ids
      end
    end
  end
end
