# Split from steps_test.exs: the send-back prompt and escalation blurb for a recipe (bd-8wdrql).
defmodule Arbiter.Worker.PrepushCheck.StepsPromptTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.PrepushCheck

  defp step_result(name, status, exit_status, output),
    do: %{
      name: name,
      cmd: "cmd-#{name} {elixir_files}",
      scope: :touched,
      status: status,
      exit_status: exit_status,
      duration_ms: 10,
      output: output,
      reason: nil
    }

  defp meta do
    steps = [
      step_result("format", :failed, 1, "FORMAT-OUTPUT"),
      step_result("compile", :passed, 0, ""),
      step_result("tests", :failed, 2, "TEST-OUTPUT"),
      step_result("credo", :skipped, nil, "skipped: nothing")
    ]

    %{
      branch: "bd-x/y",
      prepush_spec: %{command: "ignored", steps: steps},
      prepush_steps: steps
    }
  end

  test "the send-back names every failed step with its output, and the whole recipe" do
    prompt = PrepushCheck.nudge_prompt("bd-1", meta(), {:exit, 1, "FORMAT-OUTPUT"})

    assert prompt =~ "format"
    assert prompt =~ "FORMAT-OUTPUT"
    assert prompt =~ "TEST-OUTPUT"
    assert prompt =~ "exited with status 2"
    # the recipe, for re-running by hand
    assert prompt =~ "cmd-compile"
    refute prompt =~ "skipped: nothing"
    assert prompt =~ "nothing\nhas been pushed"
  end

  test "each failed step's output is bounded so the prompt stays small" do
    big = String.duplicate("x", 40_000) <> "\nEND-MARKER"

    meta =
      update_in(
        meta().prepush_steps,
        &List.replace_at(&1, 0, step_result("format", :failed, 1, big))
      )

    meta = Map.put(meta, :prepush_steps, meta.prepush_steps)

    prompt = PrepushCheck.nudge_prompt("bd-1", meta, {:exit, 1, big})
    assert prompt =~ "END-MARKER"
    assert byte_size(prompt) < 24_000
  end

  test "the escalation blurb lists the failed steps" do
    blurb =
      PrepushCheck.failure_blurb(Map.put(meta(), :prepush_detail, {:exit, 1, "FORMAT-OUTPUT"}))

    assert blurb =~ "NOT pushed"
    assert blurb =~ "format"
    assert blurb =~ "TEST-OUTPUT"
  end
end
