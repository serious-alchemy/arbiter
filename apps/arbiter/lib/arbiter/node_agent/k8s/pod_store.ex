defmodule Arbiter.NodeAgent.K8s.PodStore do
  @moduledoc """
  The pure state behind `Arbiter.NodeAgent.K8s.Informer` (K3): the pods we hold,
  keyed by name, and the resourceVersion a watch should resume from. Every
  operation returns the **transitions** it caused — `{:added | :modified |
  :deleted, pod}` — and the new store, so the informer's contract ("no loss, no
  duplicates") is decided here, in plain data:

    * An event for something we already hold at the same `resourceVersion` is
      dropped (a replayed event after a reconnect emits nothing twice).
    * A relist (`replace/3`) is diffed against the store and yields exactly the
      transitions the missed watch events would have: `deleted` for what vanished,
      `modified` for what changed, `added` for what is new.
    * Identity is name **and uid**: a pod recreated under the same name is a
      `deleted` of the old and an `added` of the new, never a `modified`, and a
      stale `DELETED` for an older incarnation cannot remove the new one.
    * `deleted` carries the object from the event (its final status), not the
      stale copy we held.

  resourceVersions are opaque strings: they are compared for equality only.
  """

  defstruct pods: %{}, rv: nil

  @type pod :: map()
  @type transition :: {:added | :modified | :deleted, pod()}
  @type t :: %__MODULE__{pods: %{String.t() => pod()}, rv: String.t() | nil}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec pods(t()) :: %{String.t() => pod()}
  def pods(%__MODULE__{pods: pods}), do: pods

  @spec resource_version(t()) :: String.t() | nil
  def resource_version(%__MODULE__{rv: rv}), do: rv

  @doc "Replaces the contents with a fresh list taken at `rv`; returns the diff."
  @spec replace(t(), [pod()], String.t()) :: {[transition()], t()}
  def replace(%__MODULE__{pods: old} = store, items, rv) do
    new = Map.new(items, &{name(&1), &1})

    deleted = for {n, pod} <- sorted(old), not Map.has_key?(new, n), do: {:deleted, pod}

    changed =
      Enum.flat_map(sorted(new), fn {n, pod} ->
        case Map.fetch(old, n) do
          :error -> [{:added, pod}]
          {:ok, held} -> changes(held, pod)
        end
      end)

    {deleted ++ changed, %{store | pods: new, rv: rv}}
  end

  @doc "Applies one watch event."
  @spec apply_event(t(), :added | :modified | :deleted, pod()) :: {[transition()], t()}
  def apply_event(%__MODULE__{pods: pods} = store, type, pod) when type in [:added, :modified] do
    n = name(pod)

    transitions =
      case Map.fetch(pods, n) do
        :error -> [{:added, pod}]
        {:ok, held} -> changes(held, pod)
      end

    {transitions, %{store | pods: Map.put(pods, n, pod), rv: version(pod, store.rv)}}
  end

  def apply_event(%__MODULE__{pods: pods} = store, :deleted, pod) do
    n = name(pod)
    store = %{store | rv: version(pod, store.rv)}

    case Map.fetch(pods, n) do
      {:ok, held} ->
        if uid(held) == uid(pod),
          do: {[{:deleted, pod}], %{store | pods: Map.delete(pods, n)}},
          else: {[], store}

      :error ->
        {[], store}
    end
  end

  @doc "A bookmark: nothing changed, but the watch may resume from `rv`."
  @spec bookmark(t(), String.t()) :: t()
  def bookmark(%__MODULE__{} = store, rv), do: %{store | rv: rv}

  @doc "The resourceVersion has expired (410): keep the pods for the next diff, forget the version."
  @spec expire(t()) :: t()
  def expire(%__MODULE__{} = store), do: %{store | rv: nil}

  # What changed between the pod we hold and the one we were just given.
  defp changes(held, pod) do
    cond do
      uid(held) != uid(pod) -> [{:deleted, held}, {:added, pod}]
      version(held, nil) == version(pod, nil) -> []
      true -> [{:modified, pod}]
    end
  end

  defp sorted(pods), do: Enum.sort_by(pods, fn {n, _} -> n end)
  defp name(pod), do: get_in(pod, ["metadata", "name"])
  defp uid(pod), do: get_in(pod, ["metadata", "uid"])
  defp version(pod, default), do: get_in(pod, ["metadata", "resourceVersion"]) || default
end
