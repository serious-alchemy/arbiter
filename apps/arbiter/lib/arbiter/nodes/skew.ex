defmodule Arbiter.Nodes.Skew do
  @moduledoc """
  Version-skew health of a node agent against the primary
  (`docs/design/remote-workers.md` §6). The primary decides on `hello`:

  | agent vs primary                          | health          | new assignments        |
  |-------------------------------------------|-----------------|------------------------|
  | same version                              | `:ready`        | yes                    |
  | same `proto`, different (older) version   | `:outdated`     | no, unless allow_skew  |
  | agent `proto` below the primary's `min_proto` | `:incompatible` | no                 |
  | agent newer than the primary (rollback)   | `:ahead`        | no                     |

  In every case runs already on the node continue; only *new* assignments are
  withheld. Exact match is the default because the agent embeds `Container`,
  `PrivateClone` and the run-spec decoder: a skewed agent would build a
  different container than the primary's tests assume.

  `proto` is the node protocol version (`Arbiter.Nodes.JoinScript.proto/0`).
  Pure: the caller supplies both sides.
  """

  @type health :: :ready | :outdated | :incompatible | :ahead
  @type agent :: %{version: String.t() | nil, proto: term()}
  @type primary :: %{version: String.t(), min_proto: pos_integer()}

  @doc "Every health value."
  @spec healths() :: [health()]
  def healths, do: [:ready, :outdated, :incompatible, :ahead]

  @doc "The primary's side of the comparison: its version and the oldest proto it speaks."
  @spec primary() :: primary()
  def primary do
    %{version: Arbiter.Version.app_version(), min_proto: Arbiter.Nodes.JoinScript.proto()}
  end

  @doc "The agent's health relative to `primary`."
  @spec health(agent(), primary()) :: health()
  def health(%{version: agent_version, proto: proto}, %{version: version, min_proto: min_proto}) do
    cond do
      not (is_integer(proto) and proto >= min_proto) -> :incompatible
      normalize(agent_version) == normalize(version) -> :ready
      true -> compare(agent_version, version)
    end
  end

  @doc "Whether a node of this health may take a new assignment (`allow_skew?`: `nodes.allow_skew`)."
  @spec assignable?(health(), boolean()) :: boolean()
  def assignable?(:ready, _allow_skew?), do: true
  def assignable?(:outdated, allow_skew?), do: allow_skew? == true
  def assignable?(_health, _allow_skew?), do: false

  defp compare(agent, primary) do
    with {:ok, a} <- parse(agent), {:ok, p} <- parse(primary) do
      if Version.compare(a, p) == :gt, do: :ahead, else: :outdated
    else
      _ -> :outdated
    end
  end

  defp parse(version) do
    case normalize(version) do
      nil -> :error
      v -> Version.parse(v)
    end
  end

  defp normalize(version) when is_binary(version),
    do: version |> String.trim() |> String.trim_leading("v")

  defp normalize(_), do: nil
end
