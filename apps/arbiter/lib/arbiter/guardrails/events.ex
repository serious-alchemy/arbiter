defmodule Arbiter.Guardrails.Events do
  @moduledoc """
  Recording and reading `Arbiter.Guardrails.Event` rows (G17,
  `docs/design/guardrail-profiles.md` §6.1).

  Capture is **best-effort**: `record/1` never raises and never changes the
  run, like `Arbiter.Worker.Egress.Audit`. A database hiccup logs a warning and
  returns `:error`; the worker carries on.

  The capture sites, one per §6.1 row:

    * Claude `permission_denials` and agy "permission check failed" steps:
      `Arbiter.Worker.ClaudeSession`, classified by `Arbiter.Guardrails.Scan.denial/2`;
    * the executed-tool-input scan: `ClaudeSession` too, via `Scan.tool_input/2`;
    * egress: `link_egress/2` folds a run's `egress_events` into events;
    * fabricated evidence: `Arbiter.Worker` when `EvidenceIntegrity` escalates;
    * self-grant: `record_self_grant/3`, called where the worker bridge or the
      MCP catalog refuses a worker's attempt.
  """

  alias Arbiter.Guardrails.Event
  alias Arbiter.Tasks.PermissionEvent
  alias Arbiter.Worker.Egress.Event, as: EgressEvent

  require Ash.Query
  require Logger

  @doc """
  Record one event. `attrs` takes the `Event` fields; `:fingerprint` defaults to
  `kind` + `detail`, so the same thing twice in one run is one event. Returns
  `:ok` also when the row already existed.
  """
  @spec record(map()) :: :ok | :error
  def record(%{} = attrs) do
    attrs = Map.put_new_lazy(attrs, :fingerprint, fn -> fingerprint(attrs) end)

    case Ash.create(Event, attrs) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "guardrail event not recorded (run=#{inspect(attrs[:run_id])} kind=#{inspect(attrs[:kind])}): #{inspect(error)}"
        )

        :error
    end
  rescue
    error ->
      Logger.warning("guardrail event not recorded: #{Exception.message(error)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("guardrail event not recorded: #{inspect(reason)}")
      :error
  end

  defp fingerprint(attrs), do: "#{attrs[:kind]}:#{attrs[:detail]}"

  @doc "Every event of a run, oldest first. `[]` on any database error."
  @spec for_run(String.t()) :: [Event.t()]
  def for_run(run_id) when is_binary(run_id) do
    Event
    |> Ash.Query.filter(run_id == ^run_id)
    |> Ash.Query.sort(:inserted_at)
    |> Ash.read!()
  rescue
    _ -> []
  end

  @doc "A run's event counts by severity, e.g. `%{major: 1, minor: 2}`."
  @spec count_by_severity(String.t()) :: %{atom() => pos_integer()}
  def count_by_severity(run_id) do
    run_id |> for_run() |> Enum.frequencies_by(& &1.severity)
  end

  @doc """
  Fold a run's `egress_events` into guardrail events, linking each to its
  source row. Idempotent: call it as often as convenient (the run's end, a
  resume).

    * a denial at a public upload host (`reason: :public_upload`): `critical`;
    * any other denial for a host:port the run never `requested` through a
      `permission_request` (`permission_events`): `major`.

  Allowed rows, and learn-mode rows the policy would have denied, are not
  events: nothing was refused. Options: `:provider`, `:model` (the subject).
  """
  @spec link_egress(String.t(), keyword()) :: :ok
  def link_egress(run_id, opts \\ []) when is_binary(run_id) do
    asked = asked_hosts(run_id)

    EgressEvent
    |> Ash.Query.filter(run_id == ^run_id and decision == :deny)
    |> Ash.Query.sort(:inserted_at)
    |> Ash.read!()
    |> Enum.each(&record_egress(&1, asked, opts))
  rescue
    error -> Logger.warning("egress link failed for #{run_id}: #{Exception.message(error)}")
  end

  defp record_egress(%{reason: :public_upload} = row, _asked, opts),
    do: egress_event(row, :public_upload_attempt, :critical, opts)

  defp record_egress(row, asked, opts) do
    host = String.downcase(row.host)

    unless MapSet.member?(asked, host) or MapSet.member?(asked, "#{host}:#{row.port}"),
      do: egress_event(row, :unrequested_egress, :major, opts)
  end

  defp egress_event(row, kind, severity, opts) do
    record(%{
      run_id: row.run_id,
      task_id: row.task_id,
      provider: opts[:provider],
      model: opts[:model],
      kind: kind,
      severity: severity,
      source: :egress,
      detail: "#{row.host}:#{row.port}",
      egress_event_id: row.id
    })
  end

  # Hosts (`host` and `host:port`) the run asked for with a `permission_request`.
  defp asked_hosts(run_id) do
    PermissionEvent
    |> Ash.Query.filter(run_id == ^run_id and event == :requested)
    |> Ash.read!()
    |> Enum.flat_map(fn %{permission: permission} ->
      case Regex.run(~r/^network\??:(.+)$/, permission) do
        [_, target] ->
          target = String.downcase(target)
          [target, target |> String.split(":") |> hd()]

        _ ->
          []
      end
    end)
    |> MapSet.new()
  end

  defp latest_run(task_id) when is_binary(task_id) do
    Arbiter.Workers.Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  rescue
    _ -> nil
  end

  defp latest_run(_), do: nil

  @doc """
  Record an attempted self-grant (`critical`): a worker trying to write
  `permissions` or `guardrails.*`, or to mint a token. `scope` is the worker's
  `Arbiter.MCP.Scope`; `what` names the surface. The run is `opts[:run_id]`, else
  the task's latest run, else the task id stands in. `provider`/`model` default
  to that run's.
  """
  @spec record_self_grant(map() | nil, String.t(), keyword()) :: :ok | :error
  def record_self_grant(scope, what, opts \\ []) when is_binary(what) do
    task_id = scope && Map.get(scope, :task_id)
    run = if opts[:run_id], do: nil, else: latest_run(task_id)

    record(%{
      run_id: opts[:run_id] || run_field(run, :id) || task_id || "unknown",
      task_id: task_id,
      provider: opts[:provider] || run_field(run, :provider),
      model: opts[:model] || run_field(run, :model),
      kind: :self_grant_attempt,
      severity: :critical,
      source: :bridge_audit,
      tool: opts[:tool],
      detail: what
    })
  end

  defp run_field(nil, _field), do: nil
  defp run_field(run, field), do: Map.get(run, field)
end
