defmodule ArbiterWeb.Api.RunJSON do
  @moduledoc """
  Render functions for `Arbiter.Workers.Run`.

  `:index` omits `output_lines` (which can be up to 500 strings) to keep list
  responses compact — clients fetch full output through `:show`.
  """

  alias Arbiter.Workers.Run

  def index(%{runs: runs}) do
    %{data: Enum.map(runs, &summary/1)}
  end

  def show(%{run: run}), do: %{data: detail(run)}

  defp summary(%Run{} = r) do
    %{
      id: r.id,
      task_id: r.task_id,
      task_title: r.task_title,
      repo: r.repo,
      workspace_id: r.workspace_id,
      # bd-1uu19b: the one run vocabulary (`Arbiter.Workers.RunState`);
      # `outcome` is nil until the run has finished.
      kind: to_string_atom(r.kind),
      state: to_string_atom(r.state),
      outcome: to_string_atom(r.outcome),
      model: r.model,
      started_at: iso(r.started_at),
      completed_at: iso(r.completed_at),
      exit_code: r.exit_code,
      failure_reason: r.failure_reason,
      failure_summary: r.failure_summary,
      resolved_skills: r.resolved_skills || [],
      standing_orders_digest: r.standing_orders_digest,
      routing_policy: r.routing_policy,
      model_tier: r.model_tier,
      thinking: r.thinking,
      difficulty_at_dispatch: r.difficulty_at_dispatch,
      provider: r.provider,
      provider_fallback: r.provider_fallback,
      # bd-40pzpj: what provider routing chose and why (nil when not routed).
      provider_account_id: r.provider_account_id,
      model_family: r.model_family,
      routing_decision: r.routing_decision,
      session_id: r.session_id,
      resumed_from_run_id: r.resumed_from_run_id
    }
  end

  defp detail(%Run{} = r) do
    summary(r)
    |> Map.merge(%{
      output_lines: Arbiter.Workers.OutputOffload.output_lines(r),
      inserted_at: iso(r.inserted_at),
      updated_at: iso(r.updated_at)
    })
  end

  defp to_string_atom(nil), do: nil
  defp to_string_atom(a) when is_atom(a), do: Atom.to_string(a)
  defp to_string_atom(s) when is_binary(s), do: s

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
