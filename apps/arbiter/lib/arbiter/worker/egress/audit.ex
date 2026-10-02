defmodule Arbiter.Worker.Egress.Audit do
  @moduledoc """
  Writes the `Arbiter.Worker.Egress.Event` row for each decision.

  Called before the proxy answers or dials, so the trail is written before
  the traffic it describes. A failed write logs a warning and does not change
  the decision: the proxy's allow/deny does not depend on the database being
  up (a DB outage must not turn into either an open or a closed egress).
  """

  require Logger

  alias Arbiter.Worker.Egress.{Event, Policy}

  @spec record(map(), {String.t(), integer()}, :allow | :deny, :allow | :deny, atom()) :: :ok
  def record(%{audit: false}, _target, _decision, _policy_verdict, _reason), do: :ok

  def record(ctx, {host, port}, decision, policy_verdict, reason) do
    attrs = %{
      run_id: ctx.run_id,
      task_id: ctx.task_id,
      host: host,
      port: port,
      decision: decision,
      policy_verdict: policy_verdict,
      mode: if(ctx.enforce, do: :enforce, else: :learn),
      reason: reason
    }

    case Ash.create(Event, attrs) do
      {:ok, _} -> :ok
      {:error, error} -> warn(attrs, error)
    end
  rescue
    error -> warn(%{run_id: ctx.run_id, host: host, port: port}, error)
  catch
    :exit, reason -> warn(%{run_id: ctx.run_id, host: host, port: port}, reason)
  end

  defp warn(attrs, error) do
    Logger.warning(
      "egress: could not record #{attrs.run_id} #{Policy.format(attrs.host, attrs.port)}: #{inspect(error)}"
    )
  end
end
