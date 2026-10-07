defmodule Arbiter.Usage.Serializer do
  @moduledoc """
  The one wire shape for `Arbiter.Usage.summarize/1` rollups (P-18, parity
  audit D-A-7), shared by `GET /api/usage` and the MCP `usage_summarize` tool.

  `total_cost_usd` is `nil` — not `0.0` — when no row in the group ever priced
  a cost (`cost_known: false`, bd-481sz7): a $0.00 would misreport an
  agy/Antigravity subscription (no dollar figure, ever) as a session that
  happened to cost nothing. Money is rounded to 6 decimals.

  `warnings/1` words the zero-token provider signal (bd-2fzwlc) that both
  surfaces now carry.
  """

  alias Arbiter.Usage.Event

  @doc "Wire shape for one rollup row."
  @spec rollup(map()) :: map()
  def rollup(%{group: g} = r) do
    %{
      group: group(g),
      rows: r.rows,
      total_cost_usd: if(r.cost_known, do: round_money(r.total_cost_usd)),
      cost_known: r.cost_known,
      estimated: Map.get(r, :estimated, false),
      tokens_in: r.tokens_in,
      tokens_out: r.tokens_out,
      thinking_tokens: r.thinking_tokens,
      cache_creation_tokens: r.cache_creation_tokens,
      cache_read_tokens: r.cache_read_tokens,
      duration_ms: r.duration_ms
    }
  end

  @spec group(term()) :: String.t() | nil
  def group(nil), do: nil
  def group(g) when is_binary(g), do: g
  def group(g) when is_atom(g), do: Atom.to_string(g)
  def group(g), do: inspect(g)

  @spec round_money(number() | nil) :: float() | nil
  def round_money(nil), do: nil
  def round_money(n) when is_number(n), do: Float.round(n / 1, 6)

  @doc "Human warnings for `Arbiter.Usage.zero_token_providers/1` reports."
  @spec warnings([map()]) :: [String.t()]
  def warnings(flagged), do: Enum.map(flagged, &warning/1)

  # bd-96mn8i round 2, finding 3: a literal-zero row (the parser matched a
  # terminal event and read no tokens out of it) is worded as the parser-bug
  # signature it is. A provider with no literal zeros — every row is
  # `tokens_in`/`tokens_out: nil` — never reached a terminal event at all
  # (e.g. every probe in the window failed auth).
  defp warning(%{provider: provider, rows: rows, zero_rows: zero_rows} = report)
       when zero_rows > 0 do
    "⚠ #{provider}: #{zero_rows} of #{rows} usage_events row(s) in this window carry literal zero " <>
      "tokens — likely a stream parser silently dropping usage rather than a genuinely free provider." <>
      unknown_suffix(report)
  end

  defp warning(%{provider: provider, rows: rows}) do
    "⚠ #{provider}: all #{rows} usage_events row(s) in this window recorded no usage at all " <>
      "(NULL tokens, not zero) — check for failed probes or an unrecognized result shape; " <>
      "these rows are excluded from cost/token aggregates, not counted as free."
  end

  defp unknown_suffix(%{unknown_rows: n}) when n > 0,
    do: " (a further #{n} row(s) recorded no usage at all — NULL, not zero.)"

  defp unknown_suffix(_report), do: ""

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

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
