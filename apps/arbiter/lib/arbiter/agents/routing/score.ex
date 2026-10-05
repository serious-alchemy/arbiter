defmodule Arbiter.Agents.Routing.Score do
  @moduledoc """
  The pure scorer behind `routing.provider_selection: scored` (bd-adtnto, R5 of
  `docs/design/paced-quota-routing-signals.md`, §2.1).

  For each surviving candidate:

      J(c) = price(c) + w(priority) × time_h(c)

    * `price(c)` — `Arbiter.Quota.Price.price/2` over the candidate's trusted
      windows (`:windows`, from `Arbiter.Quota.Headroom.windows/3`) and its
      expected draw (`:draw`, default `1.0`). With no draw estimate it is
      `1/h` on the binding window, so on its own the price reproduces
      `most_quota`'s headroom order exactly (design §9, I2);
    * `time_h(c)` — the expected hours to merge for the candidate's competence
      cell (`:time_h`, default `0.0`; the competence matrix, R6, supplies it);
    * `w(priority)` — the workspace's `routing.scoring.time_weight` for the
      ticket's **own** priority (not the epic-floor effective one), `0` for any
      priority not listed.

  `rank/2` only **reorders**: it never drops a candidate and never holds, so
  feasibility stays the paced gate's (the candidates it is handed already
  passed `gate.check`). Ties go to the larger binding headroom and then to
  configured order (`:index`); a candidate with no trusted reading ranks after
  every priced one, an infeasible one (a window at its line, which the gate
  would have dropped) before the unknown ones, both as `most_quota` does.

  Pure: no I/O, no clock.
  """

  alias Arbiter.Quota.Price
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @type config :: %{mode: :shadow | :enforce, time_weight: %{non_neg_integer() => float()}}

  @type breakdown :: %{
          price: Price.price() | nil,
          draw: float(),
          time_h: float(),
          time_term: float(),
          score: float() | nil,
          over_line?: boolean()
        }

  @doc """
  The workspace's scoring config (`routing.scoring.*`): `mode` (`:shadow`
  unless `"enforce"`) and the per-priority `time_weight` table. Malformed
  values fall back to the default, which is inert.
  """
  @spec config(Workspace.t() | nil) :: config()
  def config(%Workspace{config: config}) do
    scoring = get_in(config || %{}, ["routing", "scoring"])
    scoring = if is_map(scoring), do: scoring, else: %{}

    %{
      mode: if(Map.get(scoring, "mode") == "enforce", do: :enforce, else: :shadow),
      time_weight: time_weights(Map.get(scoring, "time_weight"))
    }
  end

  def config(_), do: %{mode: :shadow, time_weight: %{}}

  @doc "`w(priority)` for `task`'s own priority; `0.0` when unlisted."
  @spec weight(config(), Issue.t() | nil) :: float()
  def weight(%{time_weight: table}, %Issue{priority: priority}) when is_integer(priority),
    do: Map.get(table, priority, 0.0)

  def weight(_config, _task), do: 0.0

  @doc """
  Score and order `entries` (maps with `:windows`, `:headroom`, `:index`, and
  optionally `:draw` / `:time_h`), lowest `J` first. Each result carries its
  `t:breakdown/0` under `:score`.

  Option: `:weight` — `w(priority)` (default `0`).
  """
  @spec rank([map()], keyword()) :: [map()]
  def rank(entries, opts \\ []) do
    weight = Keyword.get(opts, :weight, 0) * 1.0

    entries
    |> Enum.map(&Map.put(&1, :score, breakdown(&1, weight)))
    |> Enum.sort_by(&sort_key/1)
  end

  @doc "The score breakdown of one entry under time weight `weight`."
  @spec breakdown(map(), number()) :: breakdown()
  def breakdown(entry, weight) do
    draw = Map.get(entry, :draw) || 1.0
    time_h = Map.get(entry, :time_h) || 0.0
    price = entry |> Map.get(:windows, []) |> Price.price(draw)
    time_term = weight * time_h

    %{
      price: price,
      draw: draw * 1.0,
      time_h: time_h * 1.0,
      time_term: time_term,
      score: if(is_number(price), do: price + time_term),
      over_line?: Price.over_line?(price)
    }
  end

  # Priced, then infeasible (by headroom), then unknown — `most_quota`'s own
  # classes. The headroom tiebreak keeps `1/h` ties (float-equal for
  # near-equal `h`) in today's order.
  defp sort_key(%{score: %{score: score}} = entry) when is_number(score),
    do: {0, score, -binding_headroom(entry), entry.index}

  defp sort_key(%{score: %{price: :infeasible}} = entry),
    do: {1, 0, -binding_headroom(entry), entry.index}

  defp sort_key(entry), do: {2, 0, 0, entry.index}

  defp binding_headroom(%{headroom: %{headroom: h}}), do: h
  defp binding_headroom(_), do: 0

  defp time_weights(%{} = table) do
    for {"P" <> digit, value} <- table,
        {priority, ""} <- [Integer.parse(digit)],
        priority in 0..4,
        is_number(value),
        value >= 0,
        into: %{},
        do: {priority, value * 1.0}
  end

  defp time_weights(_), do: %{}
end
