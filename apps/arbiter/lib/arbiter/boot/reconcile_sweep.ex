defmodule Arbiter.Boot.ReconcileSweep do
  @moduledoc """
  The boot reconcile sweep (`Arbiter.Application`'s `:reconcile_boot_task`), in its
  one order, under `Arbiter.Boot.ResumeGate`:

    1. **`Arbiter.Nodes.Recovery.await/1`** (RW12, `docs/design/remote-workers.md`
       §10.5): hand each run a node kept across the restart to a new Worker when it
       can (adoption, bd-4p1vui, §10.4.3), else pull what the node retained into the
       home clone, bounded (60 s per node, 90 s in all). It is first because everything below
       decides about runs from their rows: `Workers.Reconciler` marks a live row with
       no Worker `interrupted`, and `reconcile_resumable_tasks/1` resumes the task
       from its home clone. A resume that provisioned before the work was recovered
       would start from a stale clone, and could race a container that is still
       running.
    2. the `Workers.Reconciler` sweeps (orphans, shutdown casualties, worker
       scopes, CI waits, review passes, open PRs, resumable tasks).

  A recovery that fails, raises or exceeds its budget never stops the sweep: the
  runs degrade to their last checkpoint and the Reconciler carries on. The one
  thing the Reconciler does not do is act on a run recovery never accounted for
  (`Arbiter.Nodes.Recovery.unsettled/1`): it is on a node that may still hold its
  work, so it is neither interrupted nor is its ticket resumed; the next boot's
  recovery takes it.

  `reconciler` and `recovery` are options so the ordering can be tested.
  """

  alias Arbiter.Boot.ResumeGate
  alias Arbiter.Workers.Reconciler

  require Logger

  @doc "Run the sweep under the gate. Options: `:primary?`, `:reconciler`, `:recovery`."
  @spec run(keyword()) :: term()
  def run(opts \\ []) do
    primary? = Keyword.get_lazy(opts, :primary?, &Arbiter.SingleInstance.primary?/0)
    ResumeGate.sweep(fn -> steps(Keyword.put(opts, :primary?, primary?)) end)
  end

  @doc "The sweep's steps, without the gate."
  @spec steps(keyword()) :: term()
  def steps(opts) do
    primary? = Keyword.fetch!(opts, :primary?)
    reconciler = Keyword.get(opts, :reconciler, Reconciler)
    recovery = Keyword.get(opts, :recovery, &Arbiter.Nodes.Recovery.await/1)

    # A run on a node that Recovery has not settled stays Recovery's: its row is not
    # interrupted and its ticket is not resumed from a home clone that lacks the work.
    owned = owned_by_recovery(recover(recovery, primary?), primary?)

    reconciler.reconcile_orphaned_runs(primary?: primary?, skip_run_ids: Enum.map(owned, & &1.id))
    reconciler.reconcile_shutdown_casualties(primary?: primary?)
    reconciler.sweep_worker_scopes(primary?: primary?)
    # bd-2gc809 / bd-2yt0d2: a CI wait or a ReviewGate pass the stop cut
    # off gets its gate back before anything else looks at the ticket.
    # A gate holds no worker the later sweeps could see, so they are
    # told which tickets it covered.
    ci_waits = reconciler.reconcile_ci_waits(primary?: primary?)
    passes = reconciler.reconcile_review_passes(primary?: primary?)
    skip_ids = reconciler.restarted_ids([ci_waits, passes]) ++ Enum.map(owned, & &1.base_task_id)

    reconciler.reconcile_open_pr_tasks(primary?: primary?, skip_ids: skip_ids)
    reconciler.reconcile_resumable_tasks(primary?: primary?, skip_ids: skip_ids)
  end

  # What recovery reported: its `run_id => outcome` map, `:skipped`, or `nil` when it
  # failed to say (it raised, exited or returned something else).
  defp recover(recovery, primary?) do
    case recovery.(primary?: primary?) do
      {:ok, report} when is_map(report) and map_size(report) > 0 ->
        Logger.info("Boot: node recovery: #{summary(report)}")
        report

      {:ok, report} when is_map(report) or report == :skipped ->
        report

      _ ->
        nil
    end
  rescue
    e ->
      Logger.warning("Boot: node recovery failed (sweep continues): #{Exception.message(e)}")
      nil
  catch
    kind, reason ->
      Logger.warning("Boot: node recovery #{kind} (sweep continues): #{inspect(reason)}")
      nil
  end

  defp owned_by_recovery(:skipped, _primary?), do: []
  defp owned_by_recovery(_report, false), do: []

  defp owned_by_recovery(report, true) do
    Arbiter.Nodes.Recovery.unsettled(if is_map(report), do: report, else: %{})
  rescue
    e ->
      Logger.warning("Boot: could not list the runs recovery owns: #{Exception.message(e)}")
      []
  end

  defp summary(report) do
    counts = report |> Map.values() |> Enum.frequencies_by(&outcome/1)
    Enum.map_join(counts, ", ", fn {k, n} -> "#{n} #{k}" end)
  end

  defp outcome(:adopted), do: "adopted"
  defp outcome(:collected), do: "collected"
  defp outcome({:unreachable, reason}), do: "unreachable (#{inspect(reason)})"
end
