defmodule Arbiter.Usage.Serializer do
  @moduledoc """
  The one wire shape for the usage reads — REST (`ArbiterWeb.Api.UsageController`)
  and MCP (`usage_events_list`, `usage_calibration`) both render through it.

  Money is rounded to six decimals. A rollup's `total_cost_usd` is `nil` (not
  `0.0`) when no row in the group ever priced a cost — see
  `Arbiter.Usage.summarize/1`'s `cost_known` (bd-481sz7): a `$0.00` would
  misreport an agy/Antigravity subscription (no dollar figure, ever) as a
  session that happened to cost nothing.
  """

  alias Arbiter.Usage.Event

  @doc "One `Arbiter.Usage.summarize/1` rollup row."
  @spec rollup(map()) :: map()
  def rollup(%{group: g} = r) do
    %{
      group: group(g),
      rows: r.rows,
      total_cost_usd: if(r.cost_known, do: round_money(r.total_cost_usd)),
      tokens_in: r.tokens_in,
      tokens_out: r.tokens_out,
      thinking_tokens: r.thinking_tokens,
      cache_creation_tokens: r.cache_creation_tokens,
      cache_read_tokens: r.cache_read_tokens,
      duration_ms: r.duration_ms
    }
  end

  @doc "One raw ledger row."
  @spec event(Event.t()) :: map()
  def event(%Event{} = ev) do
    %{
      id: ev.id,
      task_id: ev.task_id,
      source: Atom.to_string(ev.source || :task),
      workspace_id: ev.workspace_id,
      repo: ev.repo,
      step: Atom.to_string(ev.step),
      model: ev.model,
      provider: ev.provider,
      tokens_in: ev.tokens_in,
      tokens_out: ev.tokens_out,
      thinking_tokens: ev.thinking_tokens,
      cache_creation_tokens: ev.cache_creation_tokens,
      cache_read_tokens: ev.cache_read_tokens,
      cost_usd: ev.cost_usd,
      duration_ms: ev.duration_ms,
      exit_status: ev.exit_status,
      occurred_at: iso(ev.occurred_at),
      session_id: ev.session_id,
      worker_run_id: ev.worker_run_id
    }
  end

  @doc """
  The `Arbiter.Usage.calibration/1` report, with the workspace it was run for
  echoed as `workspace_id`.
  """
  @spec calibration(map(), String.t() | nil) :: map()
  def calibration(report, workspace_id) do
    %{
      workspace_id: workspace_id,
      window_days: report.window_days,
      re_dispatched_flagged: report.re_dispatched_flagged,
      tiers: Enum.map(report.tiers, &tier/1),
      flagged: Enum.map(report.flagged, &flag/1)
    }
  end

  defp tier(tier) do
    %{
      difficulty: tier.difficulty,
      n: tier.n,
      n_scored: tier.n_scored,
      re_dispatched: tier.re_dispatched,
      p25: round_money(tier.p25),
      median: round_money(tier.median),
      p75: round_money(tier.p75),
      p90: round_money(tier.p90),
      under_rated: tier.under_rated,
      over_rated: tier.over_rated,
      under_rate: tier.under_rate,
      over_rate: tier.over_rate
    }
  end

  defp flag(flag) do
    %{
      task_id: flag.task_id,
      title: flag.title,
      difficulty: flag.difficulty,
      issue_type: group(flag.issue_type),
      actual_cost_usd: round_money(flag.actual_cost_usd),
      direction: Atom.to_string(flag.direction),
      suggested_difficulty: flag.suggested_difficulty,
      re_dispatched: flag.re_dispatched
    }
  end

  defp group(nil), do: nil
  defp group(g) when is_binary(g), do: g
  defp group(g) when is_atom(g), do: Atom.to_string(g)
  defp group(g), do: inspect(g)

  defp round_money(nil), do: nil
  defp round_money(n) when is_number(n), do: Float.round(n / 1, 6)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
