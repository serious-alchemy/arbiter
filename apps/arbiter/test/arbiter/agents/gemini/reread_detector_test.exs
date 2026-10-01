defmodule Arbiter.Agents.Gemini.RereadDetectorTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Gemini.RereadDetector

  @path "/w/apps/arbiter/lib/arbiter/application.ex"

  defp feed(state, calls) do
    Enum.reduce(calls, {state, []}, fn {name, params}, {st, alerts} ->
      {st, new} = RereadDetector.observe(st, name, params)
      {st, alerts ++ new}
    end)
  end

  defp full_read(path \\ @path), do: {"view_file", %{"AbsolutePath" => path}}

  test "fires on the Nth identical full-file read with no intervening write" do
    threshold = RereadDetector.threshold()
    {_, alerts} = feed(RereadDetector.new(), List.duplicate(full_read(), threshold))
    assert [%{path: @path, count: ^threshold}] = alerts
  end

  test "does not fire below the threshold" do
    {_, alerts} =
      feed(RereadDetector.new(), List.duplicate(full_read(), RereadDetector.threshold() - 1))

    assert alerts == []
  end

  test "keeps firing every threshold reads, not on every read" do
    t = RereadDetector.threshold()
    {_, alerts} = feed(RereadDetector.new(), List.duplicate(full_read(), t * 2 + 1))
    assert Enum.map(alerts, & &1.count) == [t, t * 2]
  end

  test "a write to the path resets the count (legitimate re-read after edit)" do
    t = RereadDetector.threshold()

    calls =
      List.duplicate(full_read(), t - 1) ++
        [{"replace_file_content", %{"TargetFile" => @path}}] ++
        List.duplicate(full_read(), t - 1)

    assert {_, []} = feed(RereadDetector.new(), calls)
  end

  test "write_to_file and multi_replace_file_content also reset" do
    t = RereadDetector.threshold()

    for tool <- ["write_to_file", "multi_replace_file_content"] do
      calls =
        List.duplicate(full_read(), t - 1) ++
          [{tool, %{"TargetFile" => @path}}] ++ List.duplicate(full_read(), t - 1)

      assert {_, []} = feed(RereadDetector.new(), calls)
    end
  end

  test "a write to a different path does not reset" do
    t = RereadDetector.threshold()

    calls =
      List.duplicate(full_read(), t - 1) ++
        [{"write_to_file", %{"TargetFile" => "/w/other.ex"}}, full_read()]

    assert {_, [%{path: @path}]} = feed(RereadDetector.new(), calls)
  end

  test "ranged reads are neither counted nor reset the count" do
    t = RereadDetector.threshold()
    ranged = {"view_file", %{"AbsolutePath" => @path, "StartLine" => 10, "EndLine" => 40}}

    {_, alerts} =
      feed(
        RereadDetector.new(),
        List.duplicate(ranged, t * 2) ++ List.duplicate(full_read(), t)
      )

    assert [%{count: ^t}] = alerts
  end

  test "paths are counted independently" do
    t = RereadDetector.threshold()

    calls =
      Enum.flat_map(1..(t - 1), fn _ -> [full_read(), full_read("/w/b.ex")] end)

    assert {_, []} = feed(RereadDetector.new(), calls)
  end

  test "ignores other tools and malformed params" do
    assert {_, []} =
             feed(RereadDetector.new(), [
               {"run_command", %{"CommandLine" => "ls"}},
               {"view_file", nil},
               {nil, %{}},
               {"view_file", %{"AbsolutePath" => ""}}
             ])
  end

  test "total/1 counts alerts fired" do
    t = RereadDetector.threshold()
    {st, _} = feed(RereadDetector.new(), List.duplicate(full_read(), t * 2))
    assert RereadDetector.total(st) == 2
  end
end
