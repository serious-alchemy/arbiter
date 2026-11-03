defmodule Arbiter.NodeAgent.K8s.EventLines do
  @moduledoc """
  The pure half of the event feed (bd-1nl506): the bytes of a run's NDJSON event file
  (the agent's stdio, which the worker's entry wrapper tees to a file and the pod ships
  to the controller) in, `{cursor, line}` pairs out. The counterpart of `LogLines`, for a
  source that cannot lose, reorder or re-stamp a line the way the kubelet's log can.

  Every chunk carries the **byte offset in the file** of its first byte. The reader keeps
  the offset it has consumed up to (`next/1`), so:

    * a chunk that overlaps what was taken (a retried upload) is trimmed to the new bytes;
    * a chunk that starts past it is a **gap** and is refused whole, with the offset the
      sender must resume from, so bytes are never skipped or reordered;
    * only newline-terminated lines are emitted. A final line with no newline is a
      **truncated** line (the file was cut mid-write: an OOM kill, a full volume): `finish/1`
      reports it and it is never handed on, so half a JSON object cannot be taken for the
      agent's `result` or its `arb done`.

  The cursor after a line is `"e<offset after the line>"`: opaque to the primary (`ARB2`
  frames), unique per line, and exactly the offset to resume the file from.
  """

  @type cursor :: String.t()
  @type line :: {cursor(), binary()}
  @type t :: %{next: non_neg_integer(), partial: binary()}

  @doc "A reader that resumes after `cursor` (`nil` or an unreadable one: from the start)."
  @spec new(cursor() | nil) :: t()
  def new(cursor), do: %{next: offset(cursor), partial: ""}

  @doc "The file offset the reader has consumed up to (and so the next byte it wants)."
  @spec next(t()) :: non_neg_integer()
  def next(%{next: next}), do: next

  @doc "The offset a cursor stands for (`0` for `nil` or anything unreadable)."
  @spec offset(cursor() | nil) :: non_neg_integer()
  def offset("e" <> digits) do
    case Integer.parse(digits) do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end

  def offset(_cursor), do: 0

  @doc """
  Feed the chunk that starts at file offset `at`: `{reader, {:ok, lines}}` for the lines
  it completed, or `{reader, {:gap, next}}` (reader unchanged) when it starts past `next`.
  """
  @spec feed(t(), non_neg_integer(), binary()) ::
          {t(), {:ok, [line()]} | {:gap, non_neg_integer()}}
  def feed(%{next: next} = reader, at, _bytes) when at > next, do: {reader, {:gap, next}}

  def feed(%{next: next, partial: partial} = reader, at, bytes) do
    skip = min(next - at, byte_size(bytes))
    <<_::binary-size(^skip), fresh::binary>> = bytes
    parts = String.split(partial <> fresh, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    start = next - byte_size(partial)

    {lines, _} =
      Enum.map_reduce(complete, start, fn text, from ->
        upto = from + byte_size(text) + 1
        {{"e" <> Integer.to_string(upto), text <> "\n"}, upto}
      end)

    {%{reader | next: next + byte_size(fresh), partial: rest}, {:ok, lines}}
  end

  @doc """
  The stream is over: `:complete` when it ended on a newline, `{:truncated, n}` when `n`
  bytes of an unterminated line were left (they are dropped, never emitted).
  """
  @spec finish(t()) :: :complete | {:truncated, pos_integer()}
  def finish(%{partial: ""}), do: :complete
  def finish(%{partial: partial}), do: {:truncated, byte_size(partial)}
end
