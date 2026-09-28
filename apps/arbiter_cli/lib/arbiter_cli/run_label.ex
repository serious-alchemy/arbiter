defmodule ArbiterCli.RunLabel do
  @moduledoc """
  How the CLI names a run (bd-1uu19b): its kind and its state — `review
  working`, `fix_pass finished (failed)` — in the one run vocabulary the
  server speaks on `GET /api/workers[/:task_id]` (kind / state / outcome).
  """

  @doc "`\"<kind> <state>\"`, the state carrying its outcome once finished."
  @spec label(map()) :: String.t()
  def label(run) do
    [run["kind"], state(run)] |> Enum.reject(&blank?/1) |> Enum.join(" ")
  end

  @doc "The run's state, with its outcome once finished: `finished (failed)`."
  @spec state(map()) :: String.t() | nil
  def state(%{"state" => "finished", "outcome" => outcome}) when is_binary(outcome),
    do: "finished (#{outcome})"

  def state(%{"state" => "waiting", "waiting_on" => "review_gate"}), do: "waiting (review gate)"
  def state(%{"state" => state}), do: state
  def state(_run), do: nil

  @doc """
  `\"  run=<id>\"` when the run runs under an id other than its ticket's (a
  ReviewGate reviewer's `<ticket>#review`), else `\"\"`.
  """
  @spec run_suffix(map()) :: String.t()
  def run_suffix(%{"run_task_id" => run_id, "task_id" => task_id})
      when is_binary(run_id) and run_id != task_id,
      do: "  run=#{run_id}"

  def run_suffix(_run), do: ""

  defp blank?(v), do: v in [nil, ""]
end
