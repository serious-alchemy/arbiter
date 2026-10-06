defmodule Arbiter.NodeAgent.Backoff do
  @moduledoc """
  Reconnect delay for the agent's socket (`docs/design/remote-workers.md` §4.1,
  §6 step 1): 1 s doubling to 30 s, with jitter so a fleet that lost the primary
  at the same instant does not reconnect in lockstep. Pure.

  The jitter only shortens: the delay is uniform in `[0.75 * ceiling, ceiling]`.
  """

  @base_ms 1_000
  @max_ms 30_000

  @doc """
  Milliseconds to wait before reconnect attempt number `attempt` (0-based).

  Options: `:base`, `:max` (ms), `:rand` (`fn n -> 0..n integer`, for tests).
  """
  @spec delay(non_neg_integer(), keyword()) :: pos_integer()
  def delay(attempt, opts \\ []) when is_integer(attempt) and attempt >= 0 do
    base = Keyword.get(opts, :base, @base_ms)
    max = Keyword.get(opts, :max, @max_ms)
    rand = Keyword.get(opts, :rand, fn n -> :rand.uniform(n + 1) - 1 end)

    # Past 2^30 the cap has long won; clamping the shift keeps the integer small.
    ceiling = min(max, base * Integer.pow(2, min(attempt, 30)))
    floor = div(ceiling * 3, 4)
    floor + rand.(ceiling - floor)
  end
end
