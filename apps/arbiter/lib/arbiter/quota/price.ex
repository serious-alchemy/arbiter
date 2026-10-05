defmodule Arbiter.Quota.Price do
  @moduledoc """
  Headroom as a price (bd-adtnto, R5 of
  `docs/design/paced-quota-routing-signals.md`, §2.3).

  For each trusted window of a pool the price is the share of the remaining
  paced headroom a draw is expected to use:

      price(w) = δ / h(w)          h(w) = ceiling_now(w) − used(w)

  and the pool's price is the `max` over its windows (the window this draw
  strains most binds). `h` is exactly `Arbiter.Quota.Headroom`'s number, read
  from the paced line through `Arbiter.Quota.Gate.pace/6`: this module never
  derives a ceiling.

  The price is continuous and strictly decreasing in `h`, and dimensionless
  (both `δ` and `h` are fractions of the same window). A window at or over its
  line (`h <= 0`) is **infeasible** and has no finite price — it is the gate's
  own `:holding` boundary, and routing has already dropped such a candidate
  before pricing; `:infeasible` is what a caller that prices one anyway gets,
  and it sorts after every number.

  With no draw estimate `δ` is `1.0`, so the pool's price is `1/h` on the
  binding window: ranking by it ascending is ranking by
  `Headroom.binding/3` descending, which is today's `most_quota` order.

  Pure: no I/O, no clock.
  """

  # 1 / h overflows a float below this; treat such a window as infeasible
  # rather than raise `ArithmeticError`.
  @min_headroom 1.0e-300

  @type price :: float() | :infeasible

  @doc """
  The price of drawing `delta` (a fraction of the window; default `1.0`) from a
  window with `headroom` left.
  """
  @spec window_price(number(), number()) :: price()
  def window_price(headroom, delta \\ 1.0)

  def window_price(headroom, delta) when is_number(headroom) and is_number(delta) do
    if headroom < @min_headroom, do: :infeasible, else: delta / headroom
  end

  @doc """
  A pool's price: the max over `windows` (`Headroom.windows/3` entries) of the
  window price. `nil` for no windows — unknown, which ranks after every priced
  candidate, never as free. `:infeasible` when any window is at or over its line.
  """
  @spec price([%{headroom: number()}], number()) :: price() | nil
  def price(windows, delta \\ 1.0)
  def price([], _delta), do: nil

  def price(windows, delta) when is_list(windows) do
    windows
    |> Enum.map(&window_price(&1.headroom, delta))
    |> Enum.reduce(fn
      :infeasible, _acc -> :infeasible
      _price, :infeasible -> :infeasible
      price, acc -> max(price, acc)
    end)
  end

  @doc """
  The sum of per-pool prices, for a candidate that draws on several pools.
  `nil` (unknown) or `:infeasible` in any pool poisons the total.
  """
  @spec total([price() | nil]) :: price() | nil
  def total(prices) do
    Enum.reduce_while(prices, 0.0, fn
      nil, _acc -> {:halt, nil}
      :infeasible, _acc -> {:halt, :infeasible}
      price, acc -> {:cont, acc + price}
    end)
    |> case do
      :infeasible -> :infeasible
      other -> other
    end
  end

  @doc """
  Whether a price says the draw is expected to finish past the line (`>= 1`).
  Allowed — the gate checks only when a worker starts — but flagged on the
  decision record.
  """
  @spec over_line?(price() | nil) :: boolean()
  def over_line?(:infeasible), do: true
  def over_line?(price) when is_number(price), do: price >= 1.0
  def over_line?(_), do: false
end
