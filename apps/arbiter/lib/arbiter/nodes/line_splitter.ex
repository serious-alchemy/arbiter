defmodule Arbiter.Nodes.LineSplitter do
  @moduledoc """
  The line framing of an Erlang port opened with `{:line, max}`, for a remote
  run's stdout (`docs/design/remote-workers.md` §7.2): the `Worker` receives the
  same `{:eol, line}` / `{:noeol, chunk}` messages from a remote handle as it
  does from a local port.

    * a newline ends a line: `{:eol, line}` (the newline is not part of it);
    * a line longer than `max` is delivered in `max`-byte `{:noeol, chunk}` pieces
      and then the rest as `{:eol, rest}`;
    * a trailing partial line is held until the next bytes, or `flush/1`
      delivers it as `{:noeol, partial}` when the process ends.

  Pure.
  """

  @default_max 65_536

  @type frame :: {:eol | :noeol, binary()}

  @doc "Feed `bytes` after `partial`: `{frames, new_partial}`."
  @spec split(binary(), binary(), pos_integer()) :: {[frame()], binary()}
  def split(partial, bytes, max \\ @default_max) do
    do_split(partial <> bytes, max, [])
  end

  @doc "The held partial line as a final frame (`[]` when there is none)."
  @spec flush(binary()) :: [frame()]
  def flush(""), do: []
  def flush(partial), do: [{:noeol, partial}]

  defp do_split(data, max, acc) do
    case :binary.split(data, "\n") do
      [line, rest] when byte_size(line) <= max ->
        do_split(rest, max, [{:eol, line} | acc])

      [_line, _rest] ->
        <<chunk::binary-size(max), rest::binary>> = data
        do_split(rest, max, [{:noeol, chunk} | acc])

      [partial] when byte_size(partial) > max ->
        <<chunk::binary-size(max), rest::binary>> = partial
        do_split(rest, max, [{:noeol, chunk} | acc])

      [partial] ->
        {Enum.reverse(acc), partial}
    end
  end
end
