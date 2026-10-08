defmodule ArbiterWeb.Api.WorkerJSON do
  alias Arbiter.Usage.LiveSpend
  alias Arbiter.Workers.Run
  alias Arbiter.Workers.RunNode
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
  # ticket's current run from `Arbiter.Workers.Current` — through the same
  # `run/1`, in the one run vocabulary (kind / state / outcome).
  def index(%{runs: runs, costs: costs} = assigns) do
    %{
      data:
        Enum.map(runs, fn view ->
          view
          |> run()
          |> Map.merge(LiveSpend.cost_fields(Map.get(costs, view.task_id)))
        end)
    }
    |> WorkspaceParam.echo(assigns)
  end

  def show(%{current: current, runs: runs} = assigns) do
    meta = Map.get(current, :meta) || %{}

    current
    |> run()
    |> Map.merge(%{
      task_title: task_title(current),
      step_started_at: Map.get(current, :step_started_at),
      last_merger_status: Map.get(meta, :last_merger_status),
      last_checked_at: Map.get(meta, :last_checked_at),
      output_lines: Map.get(meta, :output_lines, []),
      exit_status: Map.get(meta, :exit_status),
      exited_at: Map.get(meta, :exited_at),
      result: Map.get(meta, :result),
      runs: Enum.map(runs, &recent_run/1)
    })
    |> Map.merge(LiveSpend.cost_fields(Map.get(assigns, :cost)))
  end

  # One run, as both `index` and `show` report it. `task_id` is the ticket;
  # `run_task_id` is the id the run itself runs under — a ReviewGate reviewer
  # runs under `<ticket>#review`.
  defp run(view) do
    meta = Map.get(view, :meta) || %{}
    model_id = Map.get(meta, :model) || get_in(meta, [:routing_config, :model])

    view
    |> RunNode.fields()
    |> Map.merge(%{
      task_id: view.ticket_id,
      run_task_id: view.task_id,
      run_id: Map.get(view, :run_id),
      source: to_string_atom(view.source),
      kind: to_string_atom(view.kind),
      state: to_string_atom(view.state),
      outcome: to_string_atom(view.outcome),
      waiting_on: to_string_atom(Map.get(view, :waiting_on)),
      # bd-8lq2g7: the registry key + role tell a merge-queue pass from the
      # ticket's own run.
      registry_key: Map.get(view, :registry_key),
      role: to_string_atom(Map.get(view, :role)),
      workspace_id: view.workspace_id,
      repo: view.repo,
      current_step: Map.get(view, :current_step),
      claude_session: Map.get(meta, :claude_session, false),
      activity: Map.get(meta, :activity),
      # bd-aw2cyt: what the work is actually doing, and whether a process
      # exists behind it.
      phase: phase(view),
      phase_label: Arbiter.Worker.Phase.label(Map.get(view, :phase)),
      # bd-6omte4: the dispatch the quota gate is holding for the ticket.
      held: Arbiter.Workflows.DispatchQueue.serialize_held(Map.get(view, :held)),
      agent_live: Map.get(view, :agent_live),
      started_at: view.started_at,
      completed_at: Map.get(view, :completed_at),
      mr_ref: Map.get(view, :mr_ref),
      merger_url: Map.get(view, :merger_url),
      pid: pid(Map.get(view, :pid)),
      model: Arbiter.Worker.Stats.short_model_name(model_id),
      failure_reason: stringify(Map.get(view, :failure_reason)),
      failure_summary: Map.get(meta, :failure_summary)
    })
  end

  @doc """
  A ticket's current run as `GET /api/issues/:id` carries it (bd-6fkgvo):
  kind, state, outcome and phase in the run vocabulary, no transcript. nil
  stays nil.
  """
  def current_run(nil), do: nil

  def current_run(view) do
    view
    |> run()
    |> Map.take([
      :run_id,
      :run_task_id,
      :source,
      :kind,
      :state,
      :outcome,
      :waiting_on,
      :role,
      :node_id,
      :node_name,
      :phase,
      :phase_label,
      :started_at,
      :completed_at,
      :failure_reason
    ])
  end

  # A recent run in `show`'s `runs` list: the same vocabulary, no transcript.
  defp recent_run(view) do
    view
    |> run()
    |> Map.take([
      :run_id,
      :run_task_id,
      :source,
      :kind,
      :state,
      :outcome,
      :role,
      :node_id,
      :node_name,
      :model,
      :started_at,
      :completed_at,
      :failure_reason,
      :failure_summary
    ])
    |> Map.put(:current, Map.get(view, :current, false))
  end

  defp task_title(%{run: %Run{task_title: title}}), do: title
  defp task_title(_view), do: nil

  defp pid(nil), do: nil
  defp pid(pid), do: inspect(pid)

  defp phase(snap), do: to_string_atom(Map.get(snap, :phase))

  defp stringify(nil), do: nil
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: inspect(v)

  defp to_string_atom(nil), do: nil
  defp to_string_atom(a) when is_atom(a), do: Atom.to_string(a)
  defp to_string_atom(s) when is_binary(s), do: s
end
