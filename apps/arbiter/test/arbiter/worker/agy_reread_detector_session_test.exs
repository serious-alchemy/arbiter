defmodule Arbiter.Worker.AgyRereadDetectorSessionTest do
  @moduledoc "bd-buefg4: the repeated-read detector wired into the agy stream parser."

  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.Gemini.RereadDetector
  alias Arbiter.Worker.ClaudeSession

  @path "/w/application.ex"

  defp new_session(provider \\ "gemini") do
    task_id = "bd-reread-#{System.unique_integer([:positive])}"

    %{
      task_id: task_id,
      run_id: nil,
      topic: "worker:" <> task_id,
      line_cap: ClaudeSession.line_cap(),
      done_regex: ClaudeSession.done_regex(),
      output_lines: [],
      line_buf: "",
      provider: provider,
      redact_values: []
    }
  end

  defp tool_line(name, params, state \\ "ACTIVE") do
    Jason.encode!(%{
      "event" => "step_update",
      "step_update" => %{
        "step_type" => "tool",
        "state" => state,
        "step_index" => 1,
        "tool_name" => name,
        "tool_info" => %{"name" => name, "parameters" => params}
      }
    })
  end

  defp feed(session, lines),
    do: Enum.reduce(lines, session, &ClaudeSession.handle_data(&2, &1, true))

  defp reads(n), do: List.duplicate(tool_line("view_file", %{"AbsolutePath" => @path}), n)

  test "repeated full reads with no edit raise an alert, a transcript line and a counter" do
    t = RereadDetector.threshold()
    session = feed(new_session(), reads(t))

    assert ClaudeSession.reread_alerts(session) == 1
    assert Enum.any?(session.output_lines, &(&1 =~ "re-read" and &1 =~ @path))
  end

  test "a re-read after an edit does not alert" do
    t = RereadDetector.threshold()

    session =
      feed(
        new_session(),
        reads(t - 1) ++
          [tool_line("replace_file_content", %{"TargetFile" => @path})] ++ reads(t - 1)
      )

    assert ClaudeSession.reread_alerts(session) == 0
  end

  test "the DONE half of a step is not counted a second time" do
    t = RereadDetector.threshold()

    lines =
      Enum.flat_map(
        1..(t - 1),
        fn _ ->
          [
            tool_line("view_file", %{"AbsolutePath" => @path}),
            tool_line("view_file", %{"AbsolutePath" => @path}, "DONE")
          ]
        end
      )

    assert ClaudeSession.reread_alerts(feed(new_session(), lines)) == 0
  end

  test "non-agy providers are untouched" do
    session = feed(new_session("claude"), reads(RereadDetector.threshold() * 2))
    assert ClaudeSession.reread_alerts(session) == 0
  end
end
