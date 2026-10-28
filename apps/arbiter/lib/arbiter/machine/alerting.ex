defmodule Arbiter.Machine.Alerting do
  @moduledoc """
  Tells the coordinator when a machine enters or leaves a **hard** derate
  (`Arbiter.Machine.Derate`, bd-6w7usy), replacing the ad-hoc shell thermal
  watches coordinator sessions used to run per machine.

  Entering hard raises the `machine_derate` system alert (keyed by machine name)
  and leaving it clears the alert; both are announced on the `inbox` event topic
  (`Arbiter.Alerts`), so the coordinator mailbox and stream get them and
  `arb alert list` shows it while it lasts. A soft derate is visible on the
  scheduler status and `arb node list`, but is not alert-worthy: it is the
  machine doing its job.

  System alerts are workspace-scoped (they are announced on a workspace's
  stream); a machine is not, so the alert goes on the oldest workspace.
  Best-effort: it never raises.
  """

  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Tasks.Workspace

  require Logger

  @type event :: %{
          required(:machine) => String.t(),
          required(:from) => Arbiter.Machine.Derate.level(),
          required(:to) => Arbiter.Machine.Derate.level(),
          required(:snapshot) => map()
        }

  @doc """
  Handle a level change. Option `:workspace_id` pins the workspace (tests);
  otherwise the oldest one is used.
  """
  @spec transition(event(), keyword()) :: :ok
  def transition(%{machine: machine, from: from, to: to, snapshot: snapshot}, opts \\ []) do
    cond do
      to == :hard and from != :hard -> entered(machine, snapshot, opts)
      from == :hard and to != :hard -> CoordinatorNotifier.machine_derate_cleared(machine)
      true -> :ok
    end

    :ok
  rescue
    e ->
      Logger.warning("Machine.Alerting: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  defp entered(machine, snapshot, opts) do
    ws_id =
      if Keyword.has_key?(opts, :workspace_id), do: opts[:workspace_id], else: workspace_id()

    CoordinatorNotifier.machine_derated(ws_id, machine, snapshot)
  end

  @doc false
  def workspace_id do
    case Ash.read(Workspace) do
      {:ok, [_ | _] = workspaces} ->
        workspaces |> Enum.min_by(& &1.created_at, DateTime) |> Map.fetch!(:id)

      _ ->
        nil
    end
  end
end
