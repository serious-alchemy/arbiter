defmodule Arbiter.Sessions.Memory.Frontmatter do
  @moduledoc """
  The frontmatter block of a memory file (bd-19qve3): read it, add to it, and
  strip keys from it, without ever re-rendering the lines it does not touch.

  Line-based on purpose, like the phase-12 reader in `Arbiter.Sessions.Memory`:
  memory frontmatter only carries a handful of scalar keys, one level of
  nesting under `metadata:`, and the occasional list. Two properties matter
  more than YAML completeness:

    * **Keys stay strings.** Candidate files are written by sessions, so their
      keys are agent-supplied input and must never become atoms.
    * **Edits are surgical.** `put/2` inserts before the closing `---` (or
      replaces one top-level line in place) and `drop/2` removes lines; every
      other line, including `metadata:` and its nested children, is kept
      byte for byte, so a quarantined or promoted memory keeps the shape its
      author gave it.

  `fields/1` flattens nesting by leaf name, first occurrence wins, which is the
  same lookup the phase-12 mount has always done for `type` and `workspace_id`.
  """

  @delim "---"
  @key_line ~r/^(\s*)([A-Za-z0-9_][A-Za-z0-9_.-]*):(?:\s+(.*?))?\s*$/
  @plain_value ~r/\A[A-Za-z0-9][A-Za-z0-9_.@\/+:,=-]*\z/

  @doc """
  The block lines between the delimiters and the body after them, or `:none`
  when the text does not open with a complete frontmatter block.
  """
  @spec split(String.t()) :: {:ok, [String.t()], [String.t()]} | :none
  def split(contents) when is_binary(contents) do
    case String.split(contents, "\n") do
      [first | rest] -> split_lines(first, rest)
      _ -> :none
    end
  end

  defp split_lines(first, rest) do
    with true <- delim?(first),
         {block, [_closing | body]} <- Enum.split_while(rest, &(not delim?(&1))) do
      {:ok, block, body}
    else
      _ -> :none
    end
  end

  defp delim?(line), do: String.trim_trailing(line) == @delim

  @doc "Every `key: value` in the block, by leaf name, first occurrence wins."
  @spec fields(String.t()) :: %{optional(String.t()) => String.t()}
  def fields(contents) when is_binary(contents) do
    case split(contents) do
      {:ok, block, _body} -> Enum.reduce(block, %{}, &collect_field/2)
      :none -> %{}
    end
  end

  defp collect_field(line, acc) do
    case Regex.run(@key_line, line) do
      [_, _indent, key, value] when value != "" -> Map.put_new(acc, key, unquote_value(value))
      _ -> acc
    end
  end

  defp unquote_value("\"" <> _ = value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_binary(decoded) -> decoded
      _ -> value
    end
  end

  defp unquote_value("'" <> rest = value) do
    if String.ends_with?(rest, "'"), do: String.trim_trailing(rest, "'"), else: value
  end

  defp unquote_value(value), do: value

  @doc "The text after the frontmatter block, or the whole text when there is none."
  @spec body(String.t()) :: String.t()
  def body(contents) when is_binary(contents) do
    case split(contents) do
      {:ok, _block, body} -> Enum.join(body, "\n")
      :none -> contents
    end
  end

  @doc """
  Set top-level `key: value` pairs. A key already present at the top level is
  replaced on its own line; a new one is inserted just before the closing
  delimiter. A file with no frontmatter gets a block prepended.

  Values are collapsed to one line, and quoted unless they are a plain token,
  so no value can open a new key or close the block.
  """
  @spec put(String.t(), [{String.t(), String.t()}]) :: String.t()
  def put(contents, pairs) when is_binary(contents) and is_list(pairs) do
    rendered = Enum.map(pairs, fn {key, value} -> {key, render(key, value)} end)

    case split(contents) do
      {:ok, block, body} ->
        block = Enum.reduce(rendered, block, &put_line/2)
        join(block, body)

      :none ->
        Enum.join([@delim | Enum.map(rendered, &elem(&1, 1))] ++ [@delim, contents], "\n")
    end
  end

  defp put_line({key, line}, block) do
    case Enum.find_index(block, &top_level_key?(&1, key)) do
      nil -> block ++ [line]
      index -> List.replace_at(block, index, line)
    end
  end

  defp top_level_key?(line, key) do
    match?([_, "", ^key | _], Regex.run(@key_line, line))
  end

  defp render(key, value) do
    value = value |> to_string() |> String.split() |> Enum.join(" ")
    "#{key}: #{quote_value(value)}"
  end

  defp quote_value(value) do
    if Regex.match?(@plain_value, value), do: value, else: Jason.encode!(value)
  end

  @doc """
  Remove every line whose key is in `keys`, at any indentation, together with
  its children (the more-indented lines, or `- ` items, under it).
  """
  @spec drop(String.t(), [String.t()]) :: String.t()
  def drop(contents, keys) when is_binary(contents) and is_list(keys) do
    case split(contents) do
      {:ok, block, body} -> join(drop_lines(block, keys, []), body)
      :none -> contents
    end
  end

  defp drop_lines([], _keys, acc), do: Enum.reverse(acc)

  defp drop_lines([line | rest], keys, acc) do
    case Regex.run(@key_line, line) do
      [_, indent, key | _] ->
        if key in keys do
          drop_lines(Enum.drop_while(rest, &child?(&1, indent)), keys, acc)
        else
          drop_lines(rest, keys, [line | acc])
        end

      _ ->
        drop_lines(rest, keys, [line | acc])
    end
  end

  defp child?(line, indent) do
    {own_indent, text} = split_indent(line)

    text != "" and
      (String.length(own_indent) > String.length(indent) or
         (own_indent == indent and String.starts_with?(text, "- ")))
  end

  defp split_indent(line) do
    text = String.trim_leading(line)
    {String.slice(line, 0, String.length(line) - String.length(text)), text}
  end

  defp join(block, body), do: Enum.join([@delim | block] ++ [@delim | body], "\n")
end
