defmodule Arbiter.MCP.Tools.RunTests do
  @moduledoc """
  `Arbiter.MCP.Tools` handler for `run_tests` (bd-57nhsi): a worker runs `mix test`
  through Arbiter, in its own run's environment, and gets back the counts and
  each failing test's header and assertion — not the raw ExUnit output, which
  would ride in its context for the rest of the session. The full log is kept in
  the run's temp directory and its path returned.

  Worker tier, own task only. The run itself (`Arbiter.Worker.TestRun`) executes
  in this request's process; the worker GenServer is only asked where to run
  (`Arbiter.Worker.test_runner/1`).
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Worker
  alias Arbiter.Worker.TestRun

  @spec run_tests(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def run_tests(%Scope{} = scope, args) do
    with {:ok, task_id} <- Tools.resolve_task_id(scope, args, "id"),
         {:ok, request} <- request(args),
         {:ok, runner} <- runner(task_id),
         {:ok, result} <- run(runner, request) do
      {:ok, response(result)}
    end
  end

  defp request(args) do
    with {:ok, paths} <- paths(args),
         {:ok, changed} <- Tools.fetch_bool(args, "changed", false),
         {:ok, timeout} <- Tools.optional_integer(args, "timeout_seconds") do
      {:ok,
       %{paths: paths, changed: changed}
       |> then(&if(timeout, do: Map.put(&1, :timeout_s, timeout), else: &1))}
    end
  end

  defp paths(args) do
    case Map.get(args, "paths") do
      nil -> {:ok, []}
      list when is_list(list) -> if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: bad()
      _ -> bad()
    end
  end

  defp bad, do: {:error, {:invalid, "`paths` must be a list of test file or directory paths"}}

  defp runner(task_id) do
    case Worker.test_runner(task_id) do
      {:ok, runner} ->
        {:ok, runner}

      {:error, :no_worker} ->
        {:error, {:conflict, "no live worker for task #{task_id}: there is no run to test in"}}

      {:error, :no_worktree} ->
        {:error, {:conflict, "task #{task_id}'s run has no worktree to run tests in"}}
    end
  end

  defp run(runner, request) do
    case TestRun.run(runner, request) do
      {:ok, result} -> {:ok, result}
      {:error, message} -> {:error, {:invalid, message}}
    end
  end

  defp response(%{report: report, text: text, log_path: log_path} = result) do
    status = if result.ran?, do: Atom.to_string(report.status), else: "no_tests"
    base = %{status: status, summary: text}
    if log_path, do: Map.put(base, :full_log, log_path), else: base
  end
end
