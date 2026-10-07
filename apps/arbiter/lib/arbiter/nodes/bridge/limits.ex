defmodule Arbiter.Nodes.Bridge.Limits do
  @moduledoc """
  The bridge multiplexer's caps (`docs/design/remote-workers.md` §4.2, §8).

  | key | default | what it bounds |
  |-----|---------|----------------|
  | `window` | 256 KiB | bytes of one stream the peer has not yet written to its socket |
  | `frame` | 16 KiB | bytes in one `bridge.data` frame |
  | `node_cap` | 256 KiB | bytes on the link the peer's transport has not yet received, all streams together (RW2/U4) |
  | `max_streams_per_run` | 64 | concurrent streams of one run |
  | `max_streams_per_node` | 256 | concurrent streams of one node |
  | `max_stream_bytes` | 1 GiB | bytes one stream may carry in either direction over its life |
  | `max_node_bytes` | 32 GiB | bytes one channel connection may carry, both directions |

  Both ends enforce them: the sender never exceeds its own, and the receiver
  resets a stream whose peer does. They are read from
  `config :arbiter, Arbiter.Nodes.Bridge, limits: [...]`; a key not given keeps
  its default.
  """

  @defaults %{
    window: 262_144,
    frame: 16_384,
    node_cap: 262_144,
    max_streams_per_run: 64,
    max_streams_per_node: 256,
    max_stream_bytes: 1_073_741_824,
    max_node_bytes: 34_359_738_368
  }

  @type t :: %{required(atom()) => pos_integer()}

  @spec defaults() :: t()
  def defaults, do: @defaults

  @doc "The defaults with the configured overrides."
  @spec current() :: t()
  def current do
    overrides =
      :arbiter
      |> Application.get_env(Arbiter.Nodes.Bridge, [])
      |> Keyword.get(:limits, [])
      |> Map.new()
      |> Map.take(Map.keys(@defaults))

    Map.merge(@defaults, overrides)
  end
end
