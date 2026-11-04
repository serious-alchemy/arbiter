defmodule Arbiter.Nodes.Refusal do
  @moduledoc """
  A node's `refuse{reason}` is a **hold**, not a failure (`docs/design/remote-workers.md`
  §16 amendment A3, K12).

  A cluster node answers an `assign` with `refuse{no_capacity | unschedulable |
  image_unavailable | bad_spec | service_not_ready}` when it cannot start the run: its own
  admission said no (`no_capacity`), the scheduler could not place the pod within
  `schedule_s` (`unschedulable`), the digest-pinned image is not pullable
  (`image_unavailable`), the spec has a field the pod builder cannot represent
  (`bad_spec`), or a test-service sidecar crash-looped past its ready timeout before the
  worker started (`service_not_ready`, K§3.3; K14). In every case the run never started, so
  nothing about the task or the agent failed.

  Two more reasons are the primary's own (bd-bmecet, `Arbiter.Nodes.Session`'s placement
  watchdogs), for a placement that never reached a live pod because the node could not say so:
  `unacknowledged` (the controller never showed the run in its heartbeats within the ack
  budget: unreachable, or the request was lost) and `placement_lost` (the controller
  reconnected without the run, i.e. it restarted). A pod stuck Pending past the primary's
  budget is reported as `unschedulable`, with the scheduler's message as the detail. A pod that ends before its worker ever ran (the seed failed, bd-5xl6gk) is `startup_failed`, with the seed's last words as the detail.

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

  @reasons ~w(no_capacity unschedulable image_unavailable bad_spec service_not_ready unacknowledged placement_lost placement_timeout startup_failed)

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

  # bd-3jjt3p: the primary's own placement deadline (`Arbiter.Nodes.PlacementWatch`) is a
  # refusal-shaped hold too, so a pass or a `remote_only` run is held rather than failed.
  def from_start_error(
        {:claude_start_failed, {:remote_placement_failed, {:placement_timeout, stage, ms}}}
      ),
      do: {:ok, %{reason: "placement_timeout", detail: "#{stage} step exceeded #{ms}ms"}}

  # The shapes a caller that does not wrap `ClaudeSession.start/1`'s error hands back: a
  # ReviewGate reviewer's spawn is `{:worker_session_failed, {:remote_placement_failed, _}}`
  # (#1274), and the raw session error carries no wrapper at all.
  def from_start_error({:worker_session_failed, inner}), do: from_start_error(inner)

  def from_start_error({:remote_placement_failed, _} = inner),
    do: from_start_error({:claude_start_failed, inner})

  def from_start_error(_), do: :error

  @capacity_reasons ~w(no_capacity unschedulable)

  @doc """
  Is this refusal the cluster being full (#1274)? `unschedulable` (the scheduler found no room
  for the pod within `schedule_s`: worker pods rank below CI, so a CI burst causes it) and
  `no_capacity` (the node's own admission said no) pass by themselves. A pass that waits and
  asks again, placed afresh, starts once there is room. Every other reason says something about
  the run, the image or the pod, which waiting does not change.
  """
  @spec capacity?(refusal()) :: boolean()
  def capacity?(%{reason: reason}), do: reason in @capacity_reasons
  def capacity?(_), do: false

  @doc """
  SI4a (§21.4): is this refusal the pull path's — a machine node that could not pull the
  published digest (`image_unavailable{pull_failed}`) or found it short of the runtime
  contract, CLI set or provider (`image_unavailable{contract_mismatch}`)? The agent sends
  the reason's `inspect/1` as the detail. Such a refusal is not about the run: the session
  marks the node as not pulling that registry for a while (`pull_blocked`), so the requeued
  ticket goes to another node, runs on the primary (`prefer_remote`), or is held
  (`remote_only`).
  """
  @spec pull_refusal?(map()) :: boolean()
  def pull_refusal?(%{reason: "image_unavailable", detail: d}) when is_binary(d),
    do: String.starts_with?(d, "{:pull_failed") or String.starts_with?(d, "{:contract_mismatch")

  def pull_refusal?(_), do: false

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

    info
    |> Map.put(:message, message(task_id, node_name, refusal))
    |> Map.put(:phrase, short_phrase(node_name, refusal))
  end

  # The one-line form the Watchdog and the board log for every `{:no_node_capacity, info}`;
  # without it a refusal hold crashed the Watchdog that logged it (#1274).
  defp short_phrase(node_name, %{reason: reason} = refusal),
    do: "node #{node_name} refused it (#{reason}#{detail_suffix(refusal)})"

  defp message(task_id, node_name, %{reason: reason} = refusal) do
    "held — node #{node_name} refused #{task_id} (#{phrase(reason)}#{detail_suffix(refusal)}). " <>
      "It is queued again and starts when a node, or the primary where worker.placement " <>
      "allows it, can take it; no resume attempt was used."
  end

  defp phrase("no_capacity"), do: "no capacity"
  defp phrase("unschedulable"), do: "the cluster could not schedule it in time"
  defp phrase("image_unavailable"), do: "its image is not available to the node"
  defp phrase("bad_spec"), do: "the node cannot represent its spec"
  defp phrase("service_not_ready"), do: "a test service never became ready"

  defp phrase("unacknowledged"),
    do: "its controller never acknowledged the assignment, so no pod was created"

  defp phrase("placement_lost"), do: "its controller restarted and lost the assignment"

  defp phrase("placement_timeout"),
    do: "the primary's placement deadline passed before the run was placed"

  defp phrase("startup_failed"),
    do: "its pod ended while seeding, before the worker started"

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
