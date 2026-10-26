defmodule Arbiter.NodeAgent.K8s.LogLines do
  @moduledoc """
  The pure half of the `pods/log` follower (`docs/design/remote-workers.md` K§3.4): bytes
  of `GET …/log?timestamps=true` in, `{cursor, line}` pairs out.

  Every log line is `"<RFC 3339 nano timestamp> <text>"`. The timestamp is stripped; the line
  is re-terminated with `\\n` (the primary's `Arbiter.Nodes.LineSplitter` cuts the stream into
  `{:line, 65_536}` pieces itself). The **cursor** after a line is `"<timestamp> <n>"`, where
  `n` counts the lines that carry exactly that timestamp, from the first one in the log. It
  is opaque to the primary (`ARB2` frames, A4) and:

    * is **unique per line**, which the primary's replay filter needs (it drops a frame whose
      cursor equals the last one it took), even when many lines share a timestamp;
    * resumes **exactly**: `sinceTime` is truncated to the second by the API machinery
      (K1-A6), so a replay re-sends up to a second of lines, and `new/1` drops every line at
      or before the cursor (earlier timestamps, and the first `n` lines of an equal one)
      instead of keeping a window of line hashes that a controller restart would lose.
  """

  @ts ~r/\A(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?Z\z/
  @epoch "0001-01-01T00:00:00Z"

  # The container runtime cuts a line longer than its read buffer (16 KiB for containerd and
  # docker, 8 KiB for CRI-O) into partial records, and a kubelet that stamps every record
  # (older ones do; newer ones stamp only the first) writes `<timestamp> ` into the middle of
  # the line, where the record ended: a multiple of the buffer size from the line's start.
  # `unsplice/4` removes those, and only those: a fixed-width kubelet timestamp plus the
  # delimiter, at a 4 KiB boundary, not earlier than the line's own timestamp.
  @chunk 4096
  @stamp_size 30
  @stamp ~r/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{9}Z\z/

  @type cursor :: String.t()
  @type line :: {cursor(), binary()}
  @type t :: %{
          partial: binary(),
          skip: nil | {{integer(), non_neg_integer()}, pos_integer()},
          ts: String.t() | nil,
          at: {integer(), non_neg_integer()} | nil,
          n: non_neg_integer()
        }

  @doc "A fresh line reader that resumes after `cursor` (`nil`: from the start)."
  @spec new(cursor() | nil) :: t()
  def new(cursor), do: %{partial: "", skip: parse_cursor(cursor), ts: nil, at: nil, n: 0}

  @doc "The `sinceTime` to ask the API for when resuming from `cursor`."
  @spec since_time(cursor() | nil) :: String.t() | nil
  def since_time(nil), do: nil

  def since_time(cursor) do
    case String.split(cursor, " ", parts: 2) do
      [ts, _n] -> ts
      _ -> nil
    end
  end

  @doc "Feed a chunk of the response body: `{reader, lines}` for the lines it completed."
  @spec feed(t(), binary()) :: {t(), [line()]}
  def feed(%{partial: partial} = reader, chunk) do
    parts = String.split(partial <> chunk, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    reader = %{reader | partial: rest}

    {reader, lines} =
      Enum.reduce(complete, {reader, []}, fn raw, {r, acc} ->
        case take(r, raw) do
          {r, nil} -> {r, acc}
          {r, line} -> {r, [line | acc]}
        end
      end)

    {reader, Enum.reverse(lines)}
  end

  @doc "The held partial line, as a last line (the stream ended without a newline)."
  @spec flush(t()) :: [line()]
  def flush(%{partial: ""}), do: []

  def flush(%{partial: partial} = reader) do
    {_reader, line} = take(%{reader | partial: ""}, partial)
    List.wrap(line)
  end

  # -- internals ----------------------------------------------------------------

  defp take(reader, raw) do
    {ts, at, text} = split(reader, raw)
    text = unsplice(text, @chunk, at, [])
    n = if at == reader.at, do: reader.n + 1, else: 1
    reader = %{reader | ts: ts, at: at, n: n}

    if skipped?(reader.skip, at, n),
      do: {reader, nil},
      else: {%{reader | skip: nil}, {ts <> " " <> Integer.to_string(n), text <> "\n"}}
  end

  # A line with no timestamp (the API always sends one) counts as one more line at the
  # previous timestamp, so its cursor still differs from the line before it.
  defp split(reader, raw) do
    with [ts, text] <- String.split(raw, " ", parts: 2),
         {:ok, at} <- parse_ts(ts) do
      {ts, at, text}
    else
      _ -> {reader.ts || @epoch, reader.at || {0, 0}, raw}
    end
  end

  defp unsplice(rest, off, _at, acc) when byte_size(rest) < off + @stamp_size + 1,
    do: IO.iodata_to_binary([acc, rest])

  defp unsplice(rest, off, at, acc) do
    <<head::binary-size(off), stamp::binary-size(@stamp_size), delim, tail::binary>> = rest

    if delim == ?\s and spliced_stamp?(stamp, at),
      do: unsplice(tail, @chunk, at, [acc, head]),
      else: unsplice(rest, off + @chunk, at, acc)
  end

  # The kubelet's fixed `2006-01-02T15:04:05.000000000Z` form, at or after the line's own.
  defp spliced_stamp?(stamp, {secs, _} = at) do
    with true <- Regex.match?(@stamp, stamp),
         {:ok, {s, _} = stamped} <- parse_ts(stamp) do
      stamped >= at and s - secs < 3600
    else
      _ -> false
    end
  end

  defp skipped?(nil, _at, _n), do: false
  defp skipped?({since, _}, at, _n) when at < since, do: true
  defp skipped?({since, taken}, at, n) when at == since, do: n <= taken
  defp skipped?(_, _at, _n), do: false

  defp parse_cursor(nil), do: nil

  defp parse_cursor(cursor) do
    with [ts, n] <- String.split(cursor, " ", parts: 2),
         {:ok, at} <- parse_ts(ts),
         {taken, ""} when taken > 0 <- Integer.parse(n) do
      {at, taken}
    else
      _ -> nil
    end
  end

  @doc false
  @spec parse_ts(String.t()) :: {:ok, {integer(), non_neg_integer()}} | :error
  def parse_ts(text) do
    with [_, base | frac] <- Regex.run(@ts, text),
         {:ok, naive} <- NaiveDateTime.from_iso8601(base) do
      secs = naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
      nanos = frac |> List.first("") |> String.pad_trailing(9, "0") |> String.to_integer()
      {:ok, {secs, nanos}}
    else
      _ -> :error
    end
  end
end
