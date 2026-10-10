defmodule Arbiter.Nodes.Placement do
  @moduledoc """
  Where a run goes: the primary (`local`) or an enrolled node
  (`docs/design/remote-workers.md` §13, bd-aowisc §4.9). The second of
  `Worker.Dispatch`'s two admission gates, run by `ensure_node_capacity/2`
  right after `ensure_account_capacity/2` and before the ticket moves.

  ## Eligibility first

  `eligible/1` is pure and runs before any node is looked at. Only **the
  podman-backed Claude implementer** with a private clone is ever a candidate
  for a node (bd-aowisc §5, unchanged). Everything else stays on the primary,
  and `Arbiter.Nodes.LocalCapacity` is the cap that governs it:

    * every spawn kind but a fresh implementer (`:follow_up`: resumes, review
      dispatches, ReviewGate reviewers and fix rounds, merge-queue fix and
      conflict passes);
    * every non-Claude provider (`:non_claude_provider`; the podman backend is
      wired for Claude only);
    * anything not run in a podman container (`:not_podman`: bwrap-jailed or
      unsandboxed; the jail needs the primary's filesystem and keyring);
    * a dispatch with no private clone (`:no_private_clone`: task and research
      types);
    * a workspace whose `worker.placement` is `local_only`
      (`:placement_local_only`).

  The discriminator for "podman" is `GitLayout.for_policy/1`'s `:private_clone`,
  which `SecurityPolicy` merges most-restrictive-wins, so nothing a workspace,
  repo or ticket sets can loosen a run into remote.

  ## Mode

  `worker.placement` on the workspace: `local_only` (the **default**, and what
  any unreadable value means), `prefer_remote` (a node with headroom, else
  local) and `remote_only` (never local: `{:no_node_capacity, info}` and the
  card is held, not failed).

  ## Candidates

  A node is a candidate when it is online (not suspect or offline), not
  draining or revoked, healthy (`ready`), has a known cap, `live + reserved <
  cap`, its workspace pin (an allowlist; empty means any workspace) admits the
  run's workspace, and it carries every label the request asks for. They are
  ranked by lowest `live/cap`, then name, **constrained nodes last** (A3: a cluster node
  reporting `hb.capacity.constrained`, i.e. runs already `pending` on it, would only queue
  this one behind them). Under `prefer_remote` a run whose only candidates are constrained
  goes local instead (the primary's own cap still gates it); `remote_only` has no local and
  takes the constrained node as a last resort. A node reporting `degraded:
  netpol_unenforced` (A7: the cluster does not enforce NetworkPolicy, so the pod's
  deny-all is not real) is **not a candidate** unless the operator set that node's
  `allow_unenforced_network` override (`Arbiter.Nodes.update_node/3`, audited). The cap is
  `Hello.effective_max_workers/2`:
  the operator's override or the node's own suggestion, bounded by a ceiling the
  node's owner set.

  The check and the reservation run under one lock (`:global.trans/3`, local
  node only), and the reservation lives in `#{inspect(__MODULE__)}.Registry`
  keyed by task id until `release/1` (the dispatch returns) — the same shape as
  `Arbiter.Accounts.Admission` — so a burst of placements can take no more than
  the headroom.

  ## Remote execution

  `Executor.Node` exists (RW9), so `remote_execution_available?/0` is `true` by
  default and `worker.placement` (default `local_only`) is the only switch an
  operator flips. RW8 shipped it `false` ("until RW9") and nothing flipped it
  afterwards, so a real dispatch could never reach a node; the end-to-end suite
  (`:node_agent`, bd-afcoop) is what found that. `config :arbiter, remote_execution:
  false` is the kill switch.
  """

  alias Arbiter.Nodes.Overview

  @registry __MODULE__.Registry
  @modes [:local_only, :prefer_remote, :remote_only]
  @kinds [
    :implementer,
    :redispatch,
    :resume,
    :review,
    :reviewer,
    :fix_pass,
    :conflict_pass,
    :review_fix_round
  ]

  # The kinds that run in a container on a private clone (bd-7ays3v), and so
  # may run on a node once RW9 places them. The rest are bound to the primary.
  @remote_kinds [:implementer, :reviewer, :fix_pass, :conflict_pass]

  @type mode :: :local_only | :prefer_remote | :remote_only
  @type reason ::
          :follow_up
          | :non_claude_provider
          | :not_podman
          | :no_private_clone
          | :placement_local_only
  @type request :: %{
          required(:task_id) => String.t(),
          required(:kind) => atom(),
          required(:provider) => atom() | String.t() | nil,
          required(:layout) => atom() | nil,
          required(:mode) => mode(),
          optional(:workspace_id) => String.t() | nil,
          optional(:no_pr?) => boolean(),
          optional(:labels) => [String.t()]
        }
  @type info :: %{
          required(:task_id) => String.t(),
          required(:node) => String.t() | nil,
          required(:mode) => mode(),
          required(:message) => String.t(),
          optional(atom()) => term()
        }
  @type result ::
          {:ok, {:local, :no_node | {:local_only, reason()}}}
          | {:ok, {:node, map()}}
          | {:error, {:no_node_capacity, info()}}

  @doc "The placement modes, default first."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc "Every spawn kind placement knows (`LocalCapacity.kinds/0` says how each is capped)."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc """
  The mode a workspace asks for: `worker.placement`, defaulting to `:local_only`.
  An unknown or malformed value is `:local_only` too: a typo must not send a
  sensitive workspace's runs to a remote machine.
  """
  @spec mode(map() | nil) :: mode()
  def mode(%{config: %{"worker" => %{"placement" => value}}}), do: parse_mode(value)
  def mode(_), do: :local_only

  defp parse_mode(value) when is_binary(value) do
    Enum.find(@modes, :local_only, &(Atom.to_string(&1) == value))
  end

  defp parse_mode(value) when value in @modes, do: value
  defp parse_mode(_), do: :local_only

  @doc """
  `:ok` when `request` may be placed on a node, else `{:local_only, reason}`.
  Pure. See the moduledoc for the list.
  """
  @spec eligible(request()) :: :ok | {:local_only, reason()}
  def eligible(request) do
    cond do
      request.kind not in @remote_kinds -> {:local_only, :follow_up}
      not claude?(request.provider) -> {:local_only, :non_claude_provider}
      request.layout != :private_clone -> {:local_only, :not_podman}
      Map.get(request, :no_pr?, false) -> {:local_only, :no_private_clone}
      request.mode == :local_only -> {:local_only, :placement_local_only}
      true -> :ok
    end
  end

  defp claude?(provider), do: to_string(provider) == "claude"

  @doc "Why a run is local-only, as a phrase for a hold message."
  @spec reason_phrase(reason(), map()) :: String.t()
  def reason_phrase(:follow_up, %{kind: kind}),
    do: "#{kind |> to_string() |> String.replace("_", " ")} runs stay on the primary"

  def reason_phrase(:follow_up, _), do: "follow-up runs stay on the primary"

  def reason_phrase(:non_claude_provider, %{provider: provider}),
    do: "provider #{provider} has no podman path"

  def reason_phrase(:non_claude_provider, _), do: "only Claude has a podman path"

  def reason_phrase(:not_podman, _),
    do: "sandbox is not podman (bwrap-jailed or unsandboxed)"

  def reason_phrase(:no_private_clone, _), do: "no private clone (task or research dispatch)"
  def reason_phrase(:placement_local_only, _), do: "workspace worker.placement is local_only"

  @doc """
  True when placement may return a node (`Executor.Node` exists since RW9, so the
  default is `true`; `config :arbiter, remote_execution: false` turns it off).
  """
  @spec remote_execution_available?() :: boolean()
  def remote_execution_available?, do: Application.get_env(:arbiter, :remote_execution, true)

  @doc """
  Place `request`. Options: `:nodes` (rows, or a 0-arity function returning them;
  default `Arbiter.Nodes.Overview.node_rows/0`) and `:remote_available?` (a
  seam over `remote_execution_available?/0`).

    * `{:ok, {:local, why}}` — run on the primary. `why` is `:no_node` (an
      eligible run no node could take, under `prefer_remote`) or
      `{:local_only, reason}`; nothing is reserved here (the primary's own cap
      is `Arbiter.Nodes.LocalCapacity`'s).
    * `{:ok, {:node, row}}` — a slot on `row` is reserved for the calling
      process under `request.task_id`.
    * `{:error, {:no_node_capacity, info}}` — `remote_only` and nothing can take it.
  """
  @spec place(request(), keyword()) :: result()
  def place(request, opts \\ []) do
    case eligible(request) do
      {:local_only, _reason} = why ->
        {:ok, {:local, why}}

      :ok ->
        if Keyword.get_lazy(opts, :remote_available?, &remote_execution_available?/0),
          do: pick(request, opts),
          else: none(request, 0)
    end
  end

  defp pick(request, opts) do
    :global.trans(
      {{__MODULE__, :place}, self()},
      fn ->
        rows = rows(opts)
        reserved = reserved_counts()
        candidates = Enum.filter(rows, &candidate?(&1, request, reserved))

        case rank(candidates, reserved) do
          [%{constrained?: true} | _] when request.mode == :prefer_remote ->
            none(request, length(rows))

          [row | _] ->
            reserve(request.task_id, row.id)
            {:ok, {:node, row}}

          [] ->
            none(request, length(rows))
        end
      end,
      [node()]
    )
  end

  defp none(%{mode: :remote_only} = request, known) do
    info = %{
      task_id: request.task_id,
      node: nil,
      mode: :remote_only,
      nodes_known: known
    }

    {:error, {:no_node_capacity, Map.put(info, :message, refusal_message(info))}}
  end

  defp none(_request, _known), do: {:ok, {:local, :no_node}}

  defp rows(opts) do
    case Keyword.get(opts, :nodes) do
      rows when is_list(rows) -> rows
      fun when is_function(fun, 0) -> fun.()
      nil -> Overview.node_rows()
    end
  end

  defp candidate?(row, request, reserved) do
    row.state == :online and
      row.health == :ready and
      is_integer(row.max) and row.max > 0 and
      row.live + Map.get(reserved, row.id, 0) < row.max and
      network_enforced?(row) and
      pin_allows?(Map.get(row, :workspace_ids, []), Map.get(request, :workspace_id)) and
      labels_match?(Map.get(row, :labels, []), Map.get(request, :labels, []))
  end

  @doc """
  A7: false for a row reporting `degraded: netpol_unenforced` whose operator has not set
  `allow_unenforced_network`. Every other row (machine nodes, healthy clusters) is true.
  """
  @spec network_enforced?(map()) :: boolean()
  def network_enforced?(row) do
    "netpol_unenforced" not in List.wrap(Map.get(row, :degraded)) or
      Map.get(row, :allow_unenforced_network) == true
  end

  defp pin_allows?([], _workspace_id), do: true
  defp pin_allows?(pins, workspace_id), do: workspace_id in pins

  defp labels_match?(have, want), do: Enum.all?(want, &(&1 in have))

  defp rank(candidates, reserved) do
    Enum.sort_by(candidates, fn row ->
      {Map.get(row, :constrained?, false), (row.live + Map.get(reserved, row.id, 0)) / row.max,
       row.name}
    end)
  end

  @doc """
  The operator-facing refusal for `{:error, {:no_node_capacity, info}}` — one
  source of truth for MCP, the REST API (and so the CLI) and the dashboard. It
  covers both shapes of that error: no node free (`info.node == nil`) and the
  primary's own cap (`Arbiter.Nodes.LocalCapacity`, `info.node == "local"`).
  """
  @spec refusal_message(map()) :: String.t()
  def refusal_message(%{message: message}) when is_binary(message), do: message

  def refusal_message(%{task_id: task_id, mode: mode} = info) do
    "held — no node has capacity for #{task_id} (worker.placement is #{mode}; " <>
      "#{Map.get(info, :nodes_known, 0)} node(s) known). It starts when a node " <>
      "frees a slot, or when placement allows the primary."
  end

  # ---- reservations ----------------------------------------------------------

  @doc """
  Drop the calling process's reservation for `task_id` (a node slot or a slot of
  the primary's cap). A no-op when it holds none.
  """
  @spec release(String.t()) :: :ok
  def release(task_id) when is_binary(task_id) do
    Registry.unregister(@registry, task_id)
  rescue
    _ -> :ok
  end

  @doc false
  @spec reserve(String.t(), String.t()) :: :ok
  def reserve(task_id, where) do
    case Registry.register(@registry, task_id, %{node: where}) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  @doc "Every live reservation as `%{task_id:, node:, pid:}`; `node` is a node id or `\"local\"`."
  @spec reservations() :: [%{task_id: String.t(), node: String.t(), pid: pid()}]
  def reservations do
    @registry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.flat_map(fn {task_id, pid, %{node: node}} ->
      if Process.alive?(pid), do: [%{task_id: task_id, node: node, pid: pid}], else: []
    end)
  rescue
    _ -> []
  end

  defp reserved_counts do
    reservations() |> Enum.frequencies_by(& &1.node)
  end
end
