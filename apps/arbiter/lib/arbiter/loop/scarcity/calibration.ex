defmodule Arbiter.Loop.Scarcity.Calibration do
  @moduledoc """
  The pure core of draw calibration (bd-3is1nz, R3 of
  `docs/design/paced-quota-routing-signals.md`): the **window share per
  weighted token** for each model drawing on one (pool, window), fitted by
  non-negative least squares.

  `Arbiter.Loop.Scarcity` calibrates one number — Claude's 5h capacity — from
  one reading of the *current* window. That can't separate models (an Opus
  token and a Sonnet token draw differently), and it can't run for a pool whose
  history it never sees. With the append-only `quota_snapshots` history (R2)
  there is a series of readings, so each pair of consecutive captures gives one
  equation:

      share_delta  =  Σ over models m of  c_m × weighted_tokens_m  +  b × hours

  where `share_delta` is how far the window's utilization rose, the
  `weighted_tokens_m` are what `usage_events` say each model drew in the
  interval (`Arbiter.Loop.Scarcity.weighted_tokens/1`), `c_m` is the unknown
  share per weighted token, and `b` is the share per hour of traffic the ledger
  never sees (an interactive session on the same plan). Every unknown is a draw
  and so is non-negative, which is what makes this NNLS rather than ordinary
  least squares: an unconstrained fit would happily return a negative
  coefficient for a model whose few samples are noise.

  `fit/2` takes the observations (`t:observation/0`) and returns a `t:fit/0`.
  `Arbiter.Loop.Scarcity.Draw` builds the observations from the two tables.

  ## Absence is never zero

  A coefficient is a number only when the data supports one. Otherwise its
  entry carries `share_per_weighted_token: nil`, `status: :insufficient_data`
  and a `reason`:

    * `:too_few_observations` — the whole fit has too few intervals to say
      anything (default under #{8}, and never fewer than the unknowns plus two).
    * `:too_few_model_observations` — this model drew in too few intervals.
    * `:collinear` — this model's draw moves in lockstep with another's, so the
      fit can't tell their coefficients apart.
    * `:non_positive` — the fit put this model's coefficient at zero. A model
      does not draw nothing; the data simply didn't pin it down, and a `0.0`
      would read downstream as "free".

  The same discipline `Arbiter.Loop.Scarcity` applies to `window_share/2`.
  Nothing here is consumed by a routing decision: R3 is shadow output only.
  """

  @typedoc """
  One interval between two quota captures: the window-share it rose by, how
  many hours it spanned, and the weighted tokens each model drew in it.
  """
  @type observation :: %{
          required(:share) => number(),
          required(:draws) => %{String.t() => number()},
          optional(:hours) => number()
        }

  @type entry :: %{
          status: :calibrated | :insufficient_data,
          reason:
            nil | :too_few_observations | :too_few_model_observations | :collinear | :non_positive,
          share_per_weighted_token: float() | nil,
          n: non_neg_integer()
        }

  @type fit :: %{
          status: :calibrated | :insufficient_data,
          reason: nil | :too_few_observations | :no_identifiable_model,
          n: non_neg_integer(),
          models: %{String.t() => entry()},
          background_share_per_hour: float() | nil,
          rmse: float() | nil
        }

  @default_min_observations 8
  @default_min_model_observations 3

  # Relative tolerances, applied after every column is scaled to unit max.
  @zero_tol 1.0e-10
  @collinear_cos 0.99999
  @pivot_tol 1.0e-9

  @doc """
  Fit the per-model coefficients over `observations`.

  Options:

    * `:min_observations` — fewer intervals than this is `:too_few_observations`
      (default #{@default_min_observations}).
    * `:min_model_observations` — a model must draw in at least this many
      intervals to get a coefficient (default #{@default_min_model_observations}).
    * `:background` — fit the unattributed-traffic term (default `true`). It is
      dropped on its own when no observation carries `:hours`.
  """
  @spec fit([observation()], keyword()) :: fit()
  def fit(observations, opts \\ []) when is_list(observations) do
    min_obs = Keyword.get(opts, :min_observations, @default_min_observations)
    min_model = Keyword.get(opts, :min_model_observations, @default_min_model_observations)
    n = length(observations)
    models = observations |> Enum.flat_map(&Map.keys(&1.draws)) |> Enum.uniq() |> Enum.sort()
    seen = Map.new(models, &{&1, Enum.count(observations, fn o -> draw(o, &1) > 0.0 end)})
    {rich, thin} = Enum.split_with(models, &(seen[&1] >= min_model))
    {independent, collinear} = split_collinear(rich, observations)

    background? =
      Keyword.get(opts, :background, true) and Enum.any?(observations, &(hours(&1) > 0.0))

    ncols = length(independent) + if(background?, do: 1, else: 0)

    withheld =
      Map.new(thin, &{&1, absent(:too_few_model_observations, seen[&1])})
      |> Map.merge(Map.new(collinear, &{&1, absent(:collinear, seen[&1])}))

    cond do
      n < max(min_obs, ncols + 2) ->
        insufficient(models, seen, n, :too_few_observations, %{})

      independent == [] ->
        insufficient(models, seen, n, :no_identifiable_model, withheld)

      true ->
        solve(observations, independent, withheld, seen, n, background?)
    end
  end

  defp solve(observations, fit_models, withheld, seen, n, background?) do
    columns =
      Enum.map(fit_models, fn m -> Enum.map(observations, &draw(&1, m)) end) ++
        if(background?, do: [Enum.map(observations, &hours/1)], else: [])

    b = Enum.map(observations, fn o -> o.share / 1 end)
    col_scale = Enum.map(columns, &max_abs/1)
    b_scale = max_abs(b)

    if b_scale == 0.0 do
      insufficient(fit_models ++ Map.keys(withheld), seen, n, :no_identifiable_model, withheld)
    else
      scaled = Enum.zip_with(columns, col_scale, fn col, s -> Enum.map(col, &(&1 / s)) end)
      {:ok, x, blocked} = nnls(scaled, Enum.map(b, &(&1 / b_scale)))

      coefs =
        [x, col_scale]
        |> Enum.zip()
        |> Enum.map(fn {xi, s} -> xi * b_scale / s end)

      {model_coefs, bg} = Enum.split(coefs, length(fit_models))
      blocked_models = Enum.filter(blocked, &(&1 < length(fit_models)))

      entries =
        fit_models
        |> Enum.zip(model_coefs)
        |> Enum.with_index()
        |> Map.new(fn {{m, c}, i} -> {m, entry(c, i in blocked_models, seen[m])} end)
        |> Map.merge(withheld)

      %{
        status: :calibrated,
        reason: nil,
        n: n,
        models: entries,
        background_share_per_hour: background(bg),
        rmse: rmse(columns, coefs, b, n)
      }
    end
  end

  # Two models whose per-interval draw vectors point the same way can't be told
  # apart: the fit would hand all of the share to one and none to the other.
  # Both are withheld rather than reporting an arbitrary split.
  defp split_collinear(models, observations) do
    vectors = Map.new(models, fn m -> {m, Enum.map(observations, &draw(&1, m))} end)

    collinear =
      for a <- models,
          b <- models,
          a < b,
          cosine(vectors[a], vectors[b]) >= @collinear_cos,
          reduce: MapSet.new() do
        acc -> acc |> MapSet.put(a) |> MapSet.put(b)
      end

    Enum.split_with(models, &(not MapSet.member?(collinear, &1)))
  end

  defp cosine(a, b) do
    denom = :math.sqrt(norm_sq(a) * norm_sq(b))
    if denom == 0.0, do: 0.0, else: dot(a, b) / denom
  end

  defp entry(_c, true, n), do: absent(:collinear, n)

  defp entry(c, false, n) when c > 0.0,
    do: %{status: :calibrated, reason: nil, share_per_weighted_token: c, n: n}

  defp entry(_c, false, n), do: absent(:non_positive, n)

  defp absent(reason, n),
    do: %{status: :insufficient_data, reason: reason, share_per_weighted_token: nil, n: n}

  defp insufficient(models, seen, n, reason, withheld) do
    %{
      status: :insufficient_data,
      reason: reason,
      n: n,
      models: Map.new(models, &{&1, Map.get(withheld, &1) || absent(reason, seen[&1])}),
      background_share_per_hour: nil,
      rmse: nil
    }
  end

  defp background([c]) when c > 0.0, do: c
  defp background(_), do: nil

  defp rmse(columns, coefs, b, n) do
    predicted =
      columns
      |> Enum.zip(coefs)
      |> Enum.reduce(List.duplicate(0.0, n), fn {col, c}, acc ->
        Enum.zip_with(acc, col, fn a, x -> a + c * x end)
      end)

    sq = b |> Enum.zip(predicted) |> Enum.map(fn {y, p} -> (y - p) * (y - p) end) |> Enum.sum()
    :math.sqrt(sq / n)
  end

  defp draw(%{draws: draws}, model) do
    case Map.get(draws, model) do
      v when is_number(v) and v > 0 -> v / 1
      _ -> 0.0
    end
  end

  defp hours(obs) do
    case Map.get(obs, :hours) do
      v when is_number(v) and v > 0 -> v / 1
      _ -> 0.0
    end
  end

  defp max_abs(list), do: list |> Enum.map(&abs/1) |> Enum.max(fn -> 0.0 end)

  # ---- NNLS (Lawson & Hanson, 1974, algorithm NNLS) ------------------------

  @doc """
  Non-negative least squares: `min ‖A·x − b‖` over `x ≥ 0`, with `A` given as
  a list of columns (each a list the length of `b`).

  Returns `{:ok, x, blocked}`: `x` is one coefficient per column (`0.0` for a
  column the constraint pins), and `blocked` lists the indices of columns that
  could not enter the solution because they are linearly dependent on columns
  already in it.
  """
  @spec nnls([[number()]], [number()]) :: {:ok, [float()], [non_neg_integer()]}
  def nnls(columns, b) do
    ncols = length(columns)
    cols = columns |> Enum.map(fn c -> Enum.map(c, &(&1 / 1)) end) |> List.to_tuple()
    state = %{x: Map.new(0..(ncols - 1)//1, &{&1, 0.0}), passive: [], blocked: MapSet.new()}
    state = outer(state, cols, Enum.map(b, &(&1 / 1)), ncols, 3 * ncols + 10)
    x = Enum.map(0..(ncols - 1)//1, &Map.fetch!(state.x, &1))
    {:ok, x, state.blocked |> MapSet.to_list() |> Enum.sort()}
  end

  defp outer(state, _cols, _b, _ncols, 0), do: state

  defp outer(state, cols, b, ncols, budget) do
    resid = residual(state.x, cols, b)

    candidates =
      for j <- 0..(ncols - 1)//1,
          j not in state.passive,
          not MapSet.member?(state.blocked, j),
          w = dot(elem(cols, j), resid),
          w > @zero_tol * max(1.0, norm_sq(b)),
          do: {w, j}

    case candidates do
      [] ->
        state

      _ ->
        {_w, j} = Enum.max(candidates)

        {_outcome, next} =
          inner(%{state | passive: state.passive ++ [j]}, j, cols, b, ncols * 4 + 10)

        outer(next, cols, b, ncols, budget - 1)
    end
  end

  defp inner(state, _entered, _cols, _b, 0), do: {:ok, state}

  defp inner(state, entered, cols, b, budget) do
    case solve_passive(state.passive, cols, b) do
      :singular ->
        passive = List.delete(state.passive, entered)
        {:singular, %{state | passive: passive, blocked: MapSet.put(state.blocked, entered)}}

      {:ok, s} ->
        if Enum.all?(s, fn {_j, v} -> v > @zero_tol end) do
          x = Enum.reduce(s, state.x, fn {j, v}, acc -> Map.put(acc, j, v) end)
          {:ok, %{state | x: x}}
        else
          alpha =
            s
            |> Enum.filter(fn {_j, v} -> v <= @zero_tol end)
            |> Enum.map(fn {j, v} ->
              xj = Map.fetch!(state.x, j)
              xj / (xj - v)
            end)
            |> Enum.min()

          x =
            Enum.reduce(s, state.x, fn {j, v}, acc ->
              xj = Map.fetch!(acc, j)
              Map.put(acc, j, xj + alpha * (v - xj))
            end)

          passive = Enum.reject(state.passive, fn j -> Map.fetch!(x, j) <= @zero_tol end)
          x = Map.new(x, fn {j, v} -> {j, if(j in passive, do: v, else: 0.0)} end)
          inner(%{state | x: x, passive: passive}, entered, cols, b, budget - 1)
        end
    end
  end

  # Least squares restricted to the passive columns, by the normal equations.
  # Columns arrive scaled to unit max, so a fixed relative pivot tolerance is
  # meaningful; a pivot below it means the columns are dependent.
  defp solve_passive(passive, cols, b) do
    cs = Enum.map(passive, &elem(cols, &1))
    gram = for ci <- cs, do: for(cj <- cs, do: dot(ci, cj))
    rhs = Enum.map(cs, &dot(&1, b))

    case gauss(gram, rhs) do
      :singular -> :singular
      {:ok, sol} -> {:ok, Enum.zip(passive, sol)}
    end
  end

  defp gauss(matrix, rhs) do
    rows = Enum.zip_with(matrix, rhs, fn row, r -> row ++ [r] end)

    scale =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {r, i} -> Enum.at(r, i) end)
      |> Enum.max(fn -> 1.0 end)

    eliminate(rows, [], max(scale, 1.0))
  end

  defp eliminate([], done, _scale), do: back_substitute(done, [])

  defp eliminate(rows, done, scale) do
    {pivot, rest} =
      Enum.max_by(rows, fn [h | _] -> abs(h) end) |> then(&{&1, List.delete(rows, &1)})

    [ph | _] = pivot

    if abs(ph) < @pivot_tol * scale do
      :singular
    else
      reduced =
        Enum.map(rest, fn [h | tail] ->
          f = h / ph
          Enum.zip_with(tail, tl(pivot), fn a, p -> a - f * p end)
        end)

      eliminate(reduced, [pivot | done], scale)
    end
  end

  # `done` holds pivot rows most-recent-first; each pivot row is
  # `[lead, c_{k+1}..c_n, rhs]` over the variables still to solve for.
  defp back_substitute([], solved), do: {:ok, solved}

  defp back_substitute([row | more], solved) do
    [lead | tail] = row
    {coeffs, [r]} = Enum.split(tail, length(tail) - 1)
    value = (r - dot(coeffs, solved)) / lead
    back_substitute(more, [value | solved])
  end

  defp residual(x, cols, b) do
    n = length(b)

    pred =
      Enum.reduce(x, List.duplicate(0.0, n), fn {j, xj}, acc ->
        if xj == 0.0, do: acc, else: Enum.zip_with(acc, elem(cols, j), fn a, c -> a + xj * c end)
      end)

    Enum.zip_with(b, pred, fn y, p -> y - p end)
  end

  defp dot(a, b), do: a |> Enum.zip(b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
  defp norm_sq(a), do: dot(a, a)
end
