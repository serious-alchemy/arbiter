defmodule Arbiter.Workers.PrepushSteps do
  @moduledoc """
  Reads and writes the pre-push recipe's per-step results for a run
  (`Arbiter.Workers.PrepushStep`, bd-8wdrql).

  `record/4` is called by the worker once per gate pass with the
  `t:Arbiter.Worker.PrepushCheck.step_result/0` list; `list/1` and `to_map/1`
  feed `arb worker show` / `worker_show`.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Redaction
  alias Arbiter.Workers.PrepushStep

  @max_output_bytes 8_000

  @doc """
  Record `steps` (one gate pass, `attempt` counting from 1) against `run_id`.
  Best-effort: returns `:ok` whatever happens; a run with no id records nothing.
  """
  @spec record(String.t() | nil, String.t() | nil, pos_integer(), [map()]) :: :ok
  def record(nil, _task_id, _attempt, _steps), do: :ok

  def record(run_id, task_id, attempt, steps) when is_list(steps) do
    now = DateTime.utc_now()

    steps
    |> Enum.with_index()
    |> Enum.each(fn {step, position} ->
      attrs = %{
        run_id: run_id,
        task_id: task_id,
        attempt: attempt,
        position: position,
        name: step.name,
        cmd: step.cmd,
        scope: to_string(step.scope),
        status: step.status,
        exit_status: step.exit_status,
        duration_ms: step.duration_ms,
        output: step.output |> redact() |> bound(),
        # Keep recipe order stable under `occurred_at` sorting.
        occurred_at: DateTime.add(now, position, :microsecond)
      }

      write(attrs)
    end)
  end

  defp write(attrs) do
    case Ash.create(PrepushStep, attrs) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "PrepushSteps.record swallowed for task=#{attrs.task_id}: #{inspect(reason)}"
        )
    end
  rescue
    e ->
      Logger.warning(
        "PrepushSteps.record raised for task=#{attrs.task_id}: #{Exception.message(e)}"
      )
  end

  defp redact(text) when is_binary(text), do: Redaction.redact_patterns(text)
  defp redact(_), do: ""

  defp bound(text) do
    if byte_size(text) <= @max_output_bytes,
      do: text,
      else: binary_part(text, byte_size(text) - @max_output_bytes, @max_output_bytes)
  end

  @doc "A run's recorded steps, oldest attempt first and in recipe order within one."
  @spec list(String.t() | nil) :: [PrepushStep.t()]
  def list(nil), do: []

  def list(run_id) do
    PrepushStep
    |> Ash.Query.filter(run_id == ^run_id)
    |> Ash.Query.sort(attempt: :asc, position: :asc)
    |> Ash.read!()
  rescue
    _ -> []
  end

  @doc "A step row as the JSON-ready map `arb worker show` / `worker_show` render."
  @spec to_map(PrepushStep.t()) :: map()
  def to_map(%PrepushStep{} = s) do
    %{
      attempt: s.attempt,
      name: s.name,
      cmd: s.cmd,
      scope: s.scope,
      status: to_string(s.status),
      exit_status: s.exit_status,
      duration_ms: s.duration_ms,
      output: s.output
    }
  end
end
