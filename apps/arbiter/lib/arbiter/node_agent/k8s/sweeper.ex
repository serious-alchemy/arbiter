defmodule Arbiter.NodeAgent.K8s.Sweeper do
  @moduledoc """
  Which pods the sweeper may delete (`docs/design/remote-workers.md` K§3.6 layer 3).
  Pure: pods and the primary's `reap{install, live_set}` in, a deletion list out.

  RBAC cannot scope `delete` by label, so the **only** safety is here. A pod is
  selected only when **all** of these hold:

    * it carries all three labels `arbiter.dev/install`, `arbiter.dev/node` and
      `arbiter.dev/run`, the first two equal to this controller's own (a node
      enrolled to two installs, or two controllers in a namespace, can never sweep
      each other) and the run non-empty;
    * it is not the controller's own pod (by name or uid: the controller's pod has
      no run label, and this holds even if someone gives it one);
    * its run is outside the primary's `live_set` and outside `:protected` (runs the
      controller itself assigned a moment ago, which the primary's set may not list
      yet);
    * it is not already being deleted.

  An empty install or node id selects nothing, like the machine agent's reaper.
  """

  @install "arbiter.dev/install"
  @node "arbiter.dev/node"
  @run "arbiter.dev/run"

  @type selection :: %{name: String.t(), uid: String.t() | nil, run: String.t()}

  @doc """
  Options: `:install`, `:node` (required), `:live_set` (run ids), `:protected`
  (run ids), `:own_pod` (name), `:own_uid`.
  """
  @spec select([map()], keyword()) :: [selection()]
  def select(pods, opts) do
    install = opts[:install]
    node = opts[:node]
    keep = MapSet.new(List.wrap(opts[:live_set]) ++ List.wrap(opts[:protected]))

    if present?(install) and present?(node) do
      pods
      |> Enum.flat_map(&candidate(&1, install, node, keep, opts))
      |> Enum.sort_by(& &1.name)
    else
      []
    end
  end

  defp candidate(pod, install, node, keep, opts) do
    meta = pod["metadata"] || %{}
    labels = meta["labels"] || %{}
    run = labels[@run]

    if ours?(labels, install, node) and sweepable?(meta, run, keep, opts) do
      [%{name: meta["name"], uid: meta["uid"], run: run}]
    else
      []
    end
  end

  # All three labels, the first two equal to the controller's own.
  defp ours?(labels, install, node),
    do: labels[@install] == install and labels[@node] == node and present?(labels[@run])

  defp sweepable?(meta, run, keep, opts) do
    not MapSet.member?(keep, run) and not own?(meta, opts) and
      is_nil(meta["deletionTimestamp"]) and is_binary(meta["name"])
  end

  defp own?(meta, opts) do
    meta["name"] == opts[:own_pod] or (present?(opts[:own_uid]) and meta["uid"] == opts[:own_uid])
  end

  defp present?(value), do: is_binary(value) and value != ""
end
