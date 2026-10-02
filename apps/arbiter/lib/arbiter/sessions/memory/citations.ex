defmodule Arbiter.Sessions.Memory.Citations do
  @moduledoc """
  What a memory body points at (bd-19qve3) — pure extraction, no I/O.
  `Arbiter.Sessions.Memory.Staleness` decides which of these to verify for
  which memory type, and how.

    * **`file:line`** — a repo-relative path with at least one directory and an
      extension, then `:N` (a `:N-M` range is anchored on `N`). Bare filenames
      (`memory.ex:81`) are ambiguous and skipped; `host:port` forms
      (`127.0.0.1:4848`, `example.com:443`) never match because they have no
      directory; paths inside URLs never match because a citation must start
      at a word boundary that is not `/`; absolute and `..` paths are refused
      so a citation can never name anything outside the checkout.
    * **Modules** — dotted CamelCase names (`Arbiter.Sessions.Memory`). Whether
      one is a citation of the workspace or a mention of a dependency is the
      checker's call, not this module's.
    * **Ticket ids** — `<prefix>-<id>` for a known workspace prefix, where the
      id has at least one digit. A digitless id (`bd-cyxzvq`) is
      indistinguishable from a hyphenated word (`vs-code`), so it is skipped
      rather than risk quarantining a memory over English.
    * **URLs** — `http(s)://…`. Listed so a verdict can mark them `unchecked`;
      nothing ever fetches them.
  """

  @file_citation ~r/(?:^|[\s"'(\[`<])((?:[\w.-]+\/)+[\w.-]+\.[A-Za-z0-9]+):(\d+)(?:-\d+)?/
  @module ~r/\b([A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)+)\b/
  @url ~r/https?:\/\/[^\s<>()\[\]"'`]+/

  @type file_citation :: %{ref: String.t(), path: String.t(), line: pos_integer()}

  @doc "Every `file:line` citation, in order of first appearance."
  @spec files(String.t()) :: [file_citation()]
  def files(body) when is_binary(body) do
    @file_citation
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.filter(fn [path, _line] -> inside_checkout?(path) end)
    |> Enum.map(fn [path, line] ->
      %{ref: "#{path}:#{line}", path: path, line: String.to_integer(line)}
    end)
    |> Enum.uniq_by(& &1.ref)
    |> Enum.reject(&(&1.line < 1))
  end

  defp inside_checkout?(path), do: ".." not in Path.split(path)

  @doc "Every dotted module name, in order of first appearance."
  @spec modules(String.t()) :: [String.t()]
  def modules(body) when is_binary(body) do
    @module
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(&hd/1)
    |> Enum.uniq()
  end

  @doc "Every ticket id with one of `prefixes`, in order of first appearance."
  @spec tickets(String.t(), [String.t()]) :: [String.t()]
  def tickets(_body, []), do: []

  def tickets(body, prefixes) when is_binary(body) and is_list(prefixes) do
    alternatives = Enum.map_join(prefixes, "|", &Regex.escape/1)
    pattern = Regex.compile!("(?<![\\w-])((?:#{alternatives})-[0-9A-Za-z]{3,12})(?![\\w-])")

    pattern
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(&hd/1)
    |> Enum.filter(&has_digit?/1)
    |> Enum.uniq()
  end

  defp has_digit?(id) do
    [_prefix, short] = String.split(id, "-", parts: 2)
    String.match?(short, ~r/\d/)
  end

  @doc "Every http(s) URL, in order of first appearance."
  @spec urls(String.t()) :: [String.t()]
  def urls(body) when is_binary(body) do
    @url
    |> Regex.scan(body)
    |> Enum.map(fn [url] -> String.trim_trailing(url, ".") end)
    |> Enum.uniq()
  end
end
