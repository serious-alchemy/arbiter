defmodule Arbiter.Boot.ReconcileSweep do
  @moduledoc """
  The boot reconcile sweep (`Arbiter.Application`'s `:reconcile_boot_task`), in its
  one order, under `Arbiter.Boot.ResumeGate`:

    1. **`Arbiter.Nodes.Recovery.await/1`** (RW12, `docs/design/remote-workers.md`
       §10.5): pull what nodes retained across the restart into the home clones,
       bounded (60 s per node, 90 s in all). It is first because everything below
       decides about runs from their rows: `Workers.Reconciler` marks a live row with
       no Worker `interrupted`, and `reconcile_resumable_tasks/1` resumes the task
       from its home clone. A resume that provisioned before the work was recovered
       would start from a stale clone, and could race a container that is still
       running.
    2. the `Workers.Reconciler` sweeps (orphans, shutdown casualties, worker
       scopes, CI waits, review passes, open PRs, resumable tasks).

  A recovery that fails, raises or exceeds its budget never stops the sweep: the
  runs degrade to their last checkpoint and the Reconciler carries on.

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

    recover(recovery, primary?)

    reconciler.reconcile_orphaned_runs(primary?: primary?)
    reconciler.reconcile_shutdown_casualties(primary?: primary?)
    reconciler.sweep_worker_scopes(primary?: primary?)
    # bd-2gc809 / bd-2yt0d2: a CI wait or a ReviewGate pass the stop cut
    # off gets its gate back before anything else looks at the ticket.
    # A gate holds no worker the later sweeps could see, so they are
    # told which tickets it covered.
    ci_waits = reconciler.reconcile_ci_waits(primary?: primary?)
    passes = reconciler.reconcile_review_passes(primary?: primary?)
    skip_ids = reconciler.restarted_ids([ci_waits, passes])

    reconciler.reconcile_open_pr_tasks(primary?: primary?, skip_ids: skip_ids)
    reconciler.reconcile_resumable_tasks(primary?: primary?, skip_ids: skip_ids)
  end

  defp recover(recovery, primary?) do
    case recovery.(primary?: primary?) do
      {:ok, report} when is_map(report) and map_size(report) > 0 ->
        Logger.info("Boot: node recovery: #{summary(report)}")

      _ ->
        :ok
    end
  rescue
    e -> Logger.warning("Boot: node recovery failed (sweep continues): #{Exception.message(e)}")
  catch
    kind, reason ->
      Logger.warning("Boot: node recovery #{kind} (sweep continues): #{inspect(reason)}")
  end

  defp summary(report) do
    counts = report |> Map.values() |> Enum.frequencies_by(&outcome/1)
    Enum.map_join(counts, ", ", fn {k, n} -> "#{n} #{k}" end)
  end

  defp outcome(:collected), do: "collected"
  defp outcome({:unreachable, reason}), do: "unreachable (#{inspect(reason)})"
end
