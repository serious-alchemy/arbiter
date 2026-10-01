defmodule Arbiter.Agents.Gemini.RereadDetector do
  @moduledoc """
  Detects agy re-reading the same whole file over and over (bd-buefg4).

  bd-2zjtca (an agy D1 chore, 6648 s / 3.19M tokens) called `view_file` on
  `application.ex` 50 times, ~15 back to back with no edit in between; each
  full read re-adds the file to the model's context.

  Pure state machine fed one agy tool call at a time (the `ACTIVE` step's
  `tool_name` + `tool_info.parameters`):

    * a `view_file` with an `AbsolutePath` and no `StartLine`/`EndLine` is a
      *full-file read* and bumps that path's counter;
    * a ranged `view_file` is neither counted nor does it reset anything;
    * a write (`write_to_file`, `replace_file_content`,
      `multi_replace_file_content`, keyed by `TargetFile`) resets that path.

  An alert is returned when a path's counter reaches `threshold/0`, and again
  at every further multiple of it (so a 50× loop alerts ~10 times, not 46).

  This only observes: agy offers no hook to refuse or rewrite a tool call, and
  a headless `--print` session has no channel for injecting a mid-turn message,
  so the consumer (`Arbiter.Worker.ClaudeSession`) surfaces an alert as a
  transcript line, a log warning and a run-meta counter rather than a block.
  """

  @threshold 4
  @write_tools ~w(write_to_file replace_file_content multi_replace_file_content)

  @type t :: %{reads: %{String.t() => pos_integer()}, alerts: non_neg_integer()}
  @type alert :: %{path: String.t(), count: pos_integer()}

  @doc "Consecutive unchanged full reads of one path that trigger an alert."
  @spec threshold() :: pos_integer()
  def threshold, do: @threshold

  @spec new() :: t()
  def new, do: %{reads: %{}, alerts: 0}

  @doc "Number of alerts this state has emitted."
  @spec total(t()) :: non_neg_integer()
  def total(%{alerts: n}), do: n

  @spec observe(t(), String.t() | nil, map() | nil) :: {t(), [alert()]}
  def observe(state, "view_file", %{"AbsolutePath" => path} = params)
      when is_binary(path) and path != "" do
    if full_read?(params), do: bump(state, path), else: {state, []}
  end

  def observe(state, tool, %{"TargetFile" => path})
      when tool in @write_tools and is_binary(path) and path != "" do
    {%{state | reads: Map.delete(state.reads, path)}, []}
  end

  def observe(state, _tool, _params), do: {state, []}

  defp full_read?(params), do: is_nil(params["StartLine"]) and is_nil(params["EndLine"])

  defp bump(state, path) do
    count = Map.get(state.reads, path, 0) + 1
    state = %{state | reads: Map.put(state.reads, path, count)}

    if rem(count, @threshold) == 0 do
      {%{state | alerts: state.alerts + 1}, [%{path: path, count: count}]}
    else
      {state, []}
    end
  end
end
