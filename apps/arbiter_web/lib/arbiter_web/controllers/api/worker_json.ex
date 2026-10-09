defmodule ArbiterWeb.Api.WorkerJSON do
  @moduledoc """
  REST rendering of worker reads. Every payload is `Arbiter.Workers.Serializer`'s —
  the same module MCP's `worker_list` / `worker_show` render through — so this
  module only adds the REST envelope (`data`, `count`, `workspace_id`).
  """

  alias Arbiter.Workers.Serializer
  alias ArbiterWeb.Api.IssueJSON
  alias ArbiterWeb.Api.WorkspaceParam

  def dispatch(%{result: result}) do
    %{
      task: IssueJSON.data(result.task),
      worker: %{
        task_id: result.task.id,
        pid: inspect(result.worker_pid)
      },
      machine: %{
        id: result.machine_id,
        pid: inspect(result.machine_pid)
      },
      worktree_path: Map.get(result, :worktree_path),
      claude_started: not is_nil(Map.get(result, :claude_port))
    }
  end

  # bd-1uu19b: `index` and `show` render the same thing — a view of a
  # ticket's current run from `Arbiter.Workers.Current` — in the one run
  # vocabulary (kind / state / outcome). `count` and `workspace_id` ride beside
  # `data`, as they ride beside `workers` on MCP.
  def index(%{runs: runs, costs: costs} = assigns) do
    rows = Enum.map(runs, &Serializer.summary(&1, Map.get(costs, &1.task_id)))

    %{data: rows, count: length(rows)}
    |> WorkspaceParam.echo(assigns)
  end

  def show(%{current: current, runs: runs} = assigns) do
    Serializer.show(current, runs, lines: Map.get(assigns, :lines), cost: Map.get(assigns, :cost))
  end
end
