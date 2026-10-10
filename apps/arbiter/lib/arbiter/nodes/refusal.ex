defmodule Arbiter.Nodes.Refusal do
  @moduledoc """
  A node's `refuse{reason}` is a **hold**, not a failure (`docs/design/remote-workers.md`
  §16 amendment A3, K12).

  A cluster node answers an `assign` with `refuse{no_capacity | unschedulable |
  image_unavailable | bad_spec}` when it cannot start the run: its own admission said no
  (`no_capacity`), the scheduler could not place the pod within `schedule_s`
  (`unschedulable`), the digest-pinned image is not pullable (`image_unavailable`), or the
  spec has a field the pod builder cannot represent (`bad_spec`). In every case the run
  never started, so nothing about the task or the agent failed.

  `Arbiter.Worker.Dispatch` sends such a spawn error here. `hold/4`

    * ends the just-registered Worker's run `interrupted` with the typed
      `:placement_refused` cause (`Arbiter.Worker.interrupt/2`): no resume attempt is
      consumed (`meta[:resume_attempts]` is untouched) and no coordinator escalation is
      raised;
    * puts the ticket back in Ready (`requeue`), which gives its slot back (slots are counted
      by the ticket's state);
    * releases the node slot `Arbiter.Nodes.Placement` reserved for the dispatch;
    * returns `{:error, {:no_node_capacity, info}}`, the same hold every other capacity
      refusal returns, so the autopilot, the MCP tool and the CLI already know what to do with
      it.
  """

  require Logger

  alias Arbiter.Nodes.Placement
  alias Arbiter.Tasks.Issue
  alias Arbiter.Worker
  alias Arbiter.Worker.StopReason

  @reasons ~w(no_capacity unschedulable image_unavailable bad_spec)

  @type refusal :: %{reason: String.t(), detail: String.t() | nil}

  @doc "The refuse reasons of amendment A3."
  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  @doc """
  `{:ok, refusal}` when a spawn error is a node's refusal, as `ClaudeSession.start/1` wraps it
  (`{:claude_start_failed, {:remote_placement_failed, {:refused, reason, detail}}}`); `:error`
  for anything else, including a reason outside the vocabulary.
  """
  @spec from_start_error(term()) :: {:ok, refusal()} | :error
  def from_start_error({:claude_start_failed, {:remote_placement_failed, {:refused, r, d}}})
      when r in @reasons,
      do: {:ok, %{reason: r, detail: detail(d)}}

  def from_start_error(_), do: :error

  defp detail(d) when is_binary(d), do: d
  defp detail(_), do: nil

  @doc "The `{:no_node_capacity, info}` payload for a refusal by `node_name`."
  @spec info(String.t(), String.t(), refusal()) :: map()
  def info(task_id, node_name, %{reason: reason} = refusal) do
    info = %{
      task_id: task_id,
      node: node_name,
      mode: nil,
      refused: reason,
      detail: refusal[:detail]
    }

    Map.put(info, :message, message(task_id, node_name, refusal))
  end

  defp message(task_id, node_name, %{reason: reason} = refusal) do
    "held — node #{node_name} refused #{task_id} (#{phrase(reason)}#{detail_suffix(refusal)}). " <>
      "It is queued again and starts when a node, or the primary where worker.placement " <>
      "allows it, can take it; no resume attempt was used."
  end

  defp phrase("no_capacity"), do: "no capacity"
  defp phrase("unschedulable"), do: "the cluster could not schedule it in time"
  defp phrase("image_unavailable"), do: "its image is not available to the node"
  defp phrase("bad_spec"), do: "the node cannot represent its spec"

  defp detail_suffix(%{detail: d}) when is_binary(d) and d != "", do: ": " <> d
  defp detail_suffix(_), do: ""

  @doc """
  Turn a refusal into a hold for `task` (see the moduledoc). `worker_pid` is the Worker the
  dispatch registered; `node_name` the node that refused.
  """
  @spec hold(Issue.t(), pid() | nil, String.t(), refusal()) ::
          {:error, {:no_node_capacity, map()}}
  def hold(%Issue{id: task_id}, worker_pid, node_name, %{reason: reason} = refusal) do
    interrupt(worker_pid, StopReason.placement_refused(node_name, reason, refusal[:detail]))
    requeue(task_id)
    Placement.release(task_id)

    Logger.info(
      "Refusal: task=#{task_id} held — node #{node_name} refused it (#{reason}); " <>
        "run interrupted, ticket requeued, no resume attempt consumed"
    )

    {:error, {:no_node_capacity, info(task_id, node_name, refusal)}}
  end

  defp interrupt(pid, reason) when is_pid(pid) do
    if Process.alive?(pid), do: Worker.interrupt(pid, reason)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp interrupt(_pid, _reason), do: :ok

  defp requeue(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{state: state} = task} when state in [:active, :merging] ->
        case Ash.update(task, %{}, action: :requeue) do
          {:ok, _} -> :ok
          {:error, e} -> Logger.warning("Refusal: could not requeue #{task_id}: #{inspect(e)}")
        end

      _ ->
        :ok
    end
  end
end
