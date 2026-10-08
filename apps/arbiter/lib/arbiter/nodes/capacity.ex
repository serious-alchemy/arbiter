defmodule Arbiter.Nodes.Capacity do
  @moduledoc """
  How many workers the install can run: the sum of its **available** machines
  (`docs/design/remote-workers.md` §13, RW14, bd-6al9iu).

  ## The rule

      effective = min(local cap + Σ available node caps, ceiling)

    * the **local cap** is the primary's own (`Arbiter.Nodes.LocalCapacity.cap/0`);
    * a node is **available** — and adds its effective cap — only while it is
      `online`, healthy (`ready`), has a known cap, and remote execution is on
      (`Arbiter.Nodes.Placement.remote_execution_available?/0`: until it is,
      nothing can run on a node, so a node's cap would be a slot nothing can
      serve). A `draining`, `suspect`, `offline`, `lost` (its session is gone, so
      it reads `offline`) or `revoked` node adds **0**;
    * `conductor.max_concurrent` is an **optional hard ceiling**
      (`Arbiter.Board.Snapshot.concurrency_ceiling/0`): unset means "use the
      sum", set means `min(sum, ceiling)`. It stays operator-owned — it is also
      the quota valve — and is never derived from a node.

  Provider-account caps bind separately and on top (`Board.Snapshot` folds them
  in with `Accounts.Concurrency.clamp/3`): the dispatch limit is
  `min(this, account headroom)`.

  ## Placement headroom

  `placement/2` answers a narrower question for one workspace: how much of that
  capacity can *its* work use? `worker.placement` decides which machines serve
  it (`Arbiter.Nodes.Placement`):

    * `local_only` (default) — the primary only;
    * `prefer_remote` — the primary and every available node;
    * `remote_only` — the available nodes only (the primary never runs it).

  Each answer is a `cap` (a total, in the board's frame) and a `free` count (the
  slots still open on those machines, which the board adds to the running count
  the way it does for an account). A `local_only` workspace carries no `free`
  term, so an install with no nodes plans exactly as it did before. The board
  cannot see which Ready card is remote-eligible (provider, sandbox and clone
  layout are dispatch-time facts), so this is a workspace-level approximation:
  a `remote_only` workspace's local-bound work (a non-Claude provider) waits as
  well while no node has room.
  """

  alias Arbiter.Board.Snapshot
  alias Arbiter.Nodes.{LocalCapacity, Overview, Placement}

  @type node_entry :: %{
          required(:id) => String.t() | nil,
          required(:name) => String.t() | nil,
          required(:state) => atom(),
          required(:cap) => non_neg_integer() | nil,
          required(:live) => non_neg_integer(),
          required(:contributes) => non_neg_integer(),
          required(:reason) => nil | :remote_execution_off | atom()
        }

  @type breakdown :: %{
          local: non_neg_integer(),
          nodes: [node_entry()],
          remote: non_neg_integer(),
          sum: non_neg_integer(),
          ceiling: pos_integer() | nil,
          effective: non_neg_integer(),
          ceiling_cuts?: boolean(),
          remote_execution?: boolean()
        }

  @type placement :: %{cap: non_neg_integer(), free: non_neg_integer() | :unlimited}

  @doc "The primary's own cap."
  @spec local_cap() :: non_neg_integer()
  def local_cap, do: LocalCapacity.cap().cap

  @doc """
  The whole picture. Options: `:nodes` (overview rows, or a 0-arity function
  returning them; default `Overview.node_rows/0`, read only when remote
  execution is on), `:remote_available?` (a seam over
  `Placement.remote_execution_available?/0`), `:local_cap` and `:ceiling` (to
  reuse a value already read).
  """
  @spec breakdown(keyword()) :: breakdown()
  def breakdown(opts \\ []) do
    remote? = remote?(opts)
    local = Keyword.get_lazy(opts, :local_cap, &local_cap/0)
    ceiling = Keyword.get_lazy(opts, :ceiling, &Snapshot.concurrency_ceiling/0)
    nodes = opts |> rows(remote?) |> Enum.map(&entry(&1, remote?))
    remote = Enum.sum_by(nodes, & &1.contributes)
    sum = local + remote

    %{
      local: local,
      nodes: nodes,
      remote: remote,
      sum: sum,
      ceiling: ceiling,
      effective: if(ceiling, do: min(sum, ceiling), else: sum),
      ceiling_cuts?: is_integer(ceiling) and ceiling < sum,
      remote_execution?: remote?
    }
  end

  @doc "The install-wide effective concurrency: `min(sum, ceiling)`."
  @spec effective(keyword()) :: non_neg_integer()
  def effective(opts \\ []), do: breakdown(opts).effective

  @doc """
  What a workspace in placement `mode` (`t:Arbiter.Nodes.Placement.mode/0`) can
  use of the install's capacity. See the moduledoc.
  """
  @spec placement(Placement.mode(), keyword()) :: placement()
  def placement(mode, opts \\ [])

  def placement(:local_only, opts),
    do: %{cap: Keyword.get_lazy(opts, :local_cap, &local_cap/0), free: :unlimited}

  def placement(mode, opts) when mode in [:prefer_remote, :remote_only] do
    breakdown = breakdown(opts)
    reserved = reserved_counts()

    node_free =
      breakdown.nodes
      |> Enum.filter(&(&1.contributes > 0))
      |> Enum.sum_by(&max(0, &1.contributes - &1.live - Map.get(reserved, &1.id, 0)))

    case mode do
      :remote_only ->
        %{cap: breakdown.remote, free: node_free}

      :prefer_remote ->
        local_free = max(0, breakdown.local - length(LocalCapacity.holders()))
        %{cap: breakdown.sum, free: local_free + node_free}
    end
  end

  # ---- internals -------------------------------------------------------------

  defp remote?(opts) do
    Keyword.get_lazy(opts, :remote_available?, &Placement.remote_execution_available?/0)
  end

  # With remote execution off no node can contribute, so the board (which reads
  # this every tick) reads none; a caller that wants them listed passes `:nodes`.
  defp rows(opts, remote?) do
    case Keyword.get(opts, :nodes) do
      rows when is_list(rows) -> rows
      fun when is_function(fun, 0) -> fun.()
      nil -> if remote?, do: Overview.node_rows(), else: []
    end
  end

  defp entry(row, remote?) do
    cap = row[:max]
    available? = available?(row)

    %{
      id: row[:id],
      name: row[:name],
      state: row[:state],
      cap: cap,
      live: row[:live] || 0,
      contributes: if(remote? and available?, do: cap, else: 0),
      reason: unavailable_reason(row, remote?)
    }
  end

  defp available?(row) do
    row[:state] == :online and row[:health] == :ready and is_integer(row[:max]) and row[:max] > 0
  end

  defp unavailable_reason(_row, false), do: :remote_execution_off

  defp unavailable_reason(row, true) do
    cond do
      available?(row) -> nil
      row[:state] != :online -> row[:state]
      row[:health] != :ready -> :unhealthy
      true -> :no_cap
    end
  end

  defp reserved_counts do
    Placement.reservations()
    |> Enum.frequencies_by(& &1.node)
  rescue
    _ -> %{}
  end
end
