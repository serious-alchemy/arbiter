defmodule Arbiter.Board.FairShare do
  @moduledoc """
  The workspace fair-share arithmetic (DC10, bd-ag5nlo;
  `docs/design/provider-dynamic-concurrency.md` §5.3). Pure: the scheduler walk
  (`Arbiter.Board.Scheduler`) supplies the sets, this module answers the rule.

  An account with `budget_split: fair` splits a pool's budget between the
  workspaces that *demand* it, by link `weight`:

      e_w(π) = budget(π) × weight_w / Σ weight      over the demanders of π

  A workspace demands `π` when it holds a seat on `π` or has an eligible Ready
  card that can use `π` this pass. The skip rule: a card from workspace `w` is
  skipped for `π` when `w` holds at least `e_w(π)` seats and another workspace
  `v` holds fewer than `e_v(π)` and has an eligible Ready card for `π` in the
  same effective band. Nothing here stops a run: it only reorders who gets the
  next free seat, and with no such `v` the share is borrowed.

  The pool's `fair` map, as the walk carries it:

    * `:seats` — `%{workspace_id => seats held on the pool}`;
    * `:weights` — `%{workspace_id => weight}`; a workspace not named weighs 1;
    * `:labels` — `%{workspace_id => name}`, for the reason text.
  """

  @type workspace :: String.t()

  @type fair :: %{
          optional(:seats) => %{optional(workspace()) => non_neg_integer()},
          optional(:weights) => %{optional(workspace()) => pos_integer()},
          optional(:labels) => %{optional(workspace()) => String.t()}
        }

  @type yield :: %{
          workspace: workspace(),
          held: non_neg_integer(),
          share: float(),
          to: workspace(),
          to_held: non_neg_integer(),
          to_share: float()
        }

  @doc "The weight of `workspace`: its link's, else 1."
  @spec weight(fair(), workspace()) :: pos_integer()
  def weight(fair, workspace) do
    case fair |> Map.get(:weights, %{}) |> Map.get(workspace) do
      weight when is_integer(weight) and weight >= 1 -> weight
      _ -> 1
    end
  end

  @doc "Seats `workspace` holds on the pool, plus `placed` made in this walk."
  @spec held(fair(), workspace(), non_neg_integer()) :: non_neg_integer()
  def held(fair, workspace, placed \\ 0),
    do: (fair |> Map.get(:seats, %{}) |> Map.get(workspace, 0)) + placed

  @doc "`budget` split between `demanders` by weight: `%{workspace => share}`."
  @spec shares(non_neg_integer(), fair(), [workspace()]) :: %{workspace() => float()}
  def shares(budget, fair, demanders) do
    demanders = Enum.uniq(demanders)
    total = demanders |> Enum.map(&weight(fair, &1)) |> Enum.sum()

    Map.new(demanders, fn workspace ->
      {workspace, budget * weight(fair, workspace) / max(total, 1)}
    end)
  end

  @doc """
  The skip rule for a card of `workspace`. `demanders` are the workspaces
  demanding the pool, `waiting` those of them with an eligible Ready card for
  it in the card's effective band, `held` the seats each holds now (this walk's
  placements included).

  `:ok` places the card as the order would; `{:yield, details}` skips it for
  this pool, naming the workspace it yields to.
  """
  @spec check(
          workspace(),
          non_neg_integer(),
          fair(),
          [workspace()],
          [workspace()],
          %{optional(workspace()) => non_neg_integer()}
        ) :: :ok | {:yield, yield()}
  def check(workspace, budget, fair, demanders, waiting, held) do
    shares = shares(budget, fair, [workspace | demanders])
    mine = Map.get(held, workspace, 0)
    share = Map.fetch!(shares, workspace)

    with true <- mine >= share,
         other when not is_nil(other) <- most_deprived(waiting, workspace, shares, held) do
      {:yield,
       %{
         workspace: workspace,
         held: mine,
         share: share,
         to: other,
         to_held: Map.get(held, other, 0),
         to_share: Map.fetch!(shares, other)
       }}
    else
      _ -> :ok
    end
  end

  # The waiting workspace furthest under its share, by held / share, then id.
  defp most_deprived(waiting, workspace, shares, held) do
    waiting
    |> Enum.reject(&(&1 == workspace))
    |> Enum.filter(&(Map.get(held, &1, 0) < Map.get(shares, &1, 0)))
    |> Enum.min_by(&{Map.get(held, &1, 0) / Map.fetch!(shares, &1), &1}, fn -> nil end)
  end

  @doc "The reason a card yielded, in the walk's `waiting for <pool>: …` voice."
  @spec describe(yield(), fair()) :: String.t()
  def describe(yield, fair) do
    "fair share — #{label(fair, yield.workspace)} holds #{yield.held} of its " <>
      "#{format(yield.share)} share; #{label(fair, yield.to)} is under its share " <>
      "(#{yield.to_held} of #{format(yield.to_share)})"
  end

  @doc "A share for display: whole numbers bare, else one decimal."
  @spec format(number()) :: String.t()
  def format(share) when is_float(share) do
    if share == Float.round(share, 0),
      do: share |> trunc() |> to_string(),
      else: share |> Float.round(1) |> Float.to_string()
  end

  def format(share), do: to_string(share)

  defp label(fair, workspace), do: fair |> Map.get(:labels, %{}) |> Map.get(workspace, workspace)
end
